#!/bin/bash
#
# install.sh - Instalacja openshift-tools dla bieżącego użytkownika
#
# - Kopiuje narzędzia do ~/.local/share/openshift-tools
# - Dodaje je do PATH w ~/.bashrc
# - Konfiguruje login LDAP/AD i (opcjonalnie) firmowe CA
# - Pozwala od razu dodać klastry
#
# Użycie: ./install.sh [--user LOGIN] [--ca PLIK]
#

set -o pipefail

SRC_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DEST_DIR="$HOME/.local/share/openshift-tools"
CONFIG_DIR="$HOME/.config/openshift-tools"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ARG_USER=""
ARG_CA=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) ARG_USER="$2"; shift 2 ;;
        --ca)   ARG_CA="$2"; shift 2 ;;
        -h|--help)
            echo "Użycie: ./install.sh [--user LOGIN] [--ca PLIK]"
            echo ""
            echo "  --user LOGIN   Login LDAP/AD (domyślnie: pytanie)"
            echo "  --ca PLIK      Plik PEM z firmowym CA (domyślnie: pytanie)"
            exit 0
            ;;
        *)
            echo -e "${RED}Nieznana opcja: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}=== Instalacja openshift-tools ===${NC}"
echo ""

# ============================================
# 1. WYMAGANIA
# ============================================

echo -e "${CYAN}1. Wymagania:${NC}"
missing=0
for cmd in oc curl; do
    if command -v "$cmd" &> /dev/null || [[ -x "$HOME/.local/bin/$cmd" ]]; then
        echo -e "   ${GREEN}$cmd${NC}"
    else
        echo -e "   ${RED}$cmd - brak${NC}"
        missing=1
    fi
done
for cmd in tmux starship fzf; do
    if command -v "$cmd" &> /dev/null || [[ -x "$HOME/.local/bin/$cmd" ]]; then
        echo -e "   ${GREEN}$cmd${NC} (opcjonalnie)"
    else
        echo -e "   ${YELLOW}$cmd - brak (opcjonalnie)${NC}"
    fi
done
if [[ $missing -eq 1 ]]; then
    echo ""
    echo -e "${RED}Zainstaluj brakujące narzędzia (oc do ~/.local/bin lub /usr/local/bin) i uruchom ponownie.${NC}"
    exit 1
fi
echo ""

# ============================================
# 2. KOPIOWANIE NARZĘDZI
# ============================================

echo -e "${CYAN}2. Narzędzia → $DEST_DIR${NC}"
if [[ "$SRC_DIR" != "$DEST_DIR" ]]; then
    mkdir -p "$DEST_DIR"
    rm -rf "$DEST_DIR/bin" "$DEST_DIR/lib"
    cp -a "$SRC_DIR/bin" "$SRC_DIR/lib" "$SRC_DIR/config" "$DEST_DIR/" || exit 1
    chmod 755 "$DEST_DIR/bin/"*
fi
echo -e "   ${GREEN}OK${NC}"

if ! grep -q "openshift-tools/bin" "$HOME/.bashrc" 2>/dev/null; then
    {
        echo ""
        echo "# OpenShift tools"
        echo 'export PATH="$HOME/.local/bin:$HOME/.local/share/openshift-tools/bin:$PATH"'
    } >> "$HOME/.bashrc"
    echo "   Dodano do PATH w ~/.bashrc"
else
    echo "   PATH w ~/.bashrc już skonfigurowany"
fi
export PATH="$HOME/.local/bin:$DEST_DIR/bin:$PATH"
echo ""

# ============================================
# 3. UŻYTKOWNIK LDAP/AD
# ============================================

echo -e "${CYAN}3. Użytkownik LDAP/AD:${NC}"
if [[ -n "$ARG_USER" ]]; then
    ocp-login --set-user "$ARG_USER" || exit 1
else
    ocp-login --set-user || exit 1
fi
echo ""

# ============================================
# 4. FIRMOWE CA
# ============================================

echo -e "${CYAN}4. Certyfikat CA:${NC}"
echo "   Hasło AD jest wysyłane tylko do serwerów z zaufanym certyfikatem."
ca="$ARG_CA"
if [[ -z "$ca" ]]; then
    echo "   Jeśli firmowe CA jest w systemowym magazynie (/etc/pki/ca-trust), naciśnij Enter."
    read -p "   Plik PEM z firmowym CA: " ca
fi

if [[ -n "$ca" ]]; then
    ca="${ca/#\~/$HOME}"
    if [[ ! -f "$ca" ]] || ! grep -q "BEGIN CERTIFICATE" "$ca"; then
        echo -e "   ${RED}'$ca' nie jest plikiem PEM z certyfikatem${NC}"
        exit 1
    fi
    # Kopia w katalogu konfiguracji - przenoszona przez migrate-configuration.sh
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    if [[ "$(readlink -f "$ca")" != "$CONFIG_DIR/ca-bundle.pem" ]]; then
        cp "$ca" "$CONFIG_DIR/ca-bundle.pem"
    fi
    chmod 644 "$CONFIG_DIR/ca-bundle.pem"
    ocp-login --set-ca "$CONFIG_DIR/ca-bundle.pem" | sed 's/^/   /'
else
    ocp-login --set-ca none | sed 's/^/   /'
fi
echo ""

# ============================================
# 5. KONFIGURACJE OPCJONALNE
# ============================================

echo -e "${CYAN}5. Prompt starship:${NC}"
if [[ -f "$HOME/.config/starship.toml" ]]; then
    echo "   ~/.config/starship.toml już istnieje - bez zmian"
else
    mkdir -p "$HOME/.config"
    cp "$SRC_DIR/config/starship.toml" "$HOME/.config/starship.toml"
    echo "   Skopiowano do ~/.config/starship.toml"
fi
echo ""

# ============================================
# 6. POZOSTAŁOŚCI PO TOKENACH SERVICEACCOUNT
# ============================================

if [[ -d "$HOME/.kube/tokens" ]] || [[ -f "$HOME/.kube/cluster-registry.conf" ]] ||
    grep -qs "serviceaccount" "$HOME/.kube/clusters/"* 2>/dev/null; then
    echo -e "${YELLOW}6. Wykryto konfigurację z tokenami ServiceAccount (~/.kube/tokens,${NC}"
    echo -e "${YELLOW}   cluster-registry.conf). Zobacz INSTALL.md → \"Przejście z tokenów SA\".${NC}"
    echo "   Istniejące klastry w ~/.kube/clusters/ zadziałają - przy pierwszym"
    echo "   'ocp klaster' nastąpi logowanie Twoim użytkownikiem."
    echo ""
fi

# ============================================
# 7. KLASTRY
# ============================================

echo -e "${CYAN}7. Klastry:${NC}"
while true; do
    read -p "   Dodać klaster? Nazwa (Enter = koniec): " name
    [[ -z "$name" ]] && break
    read -p "   API URL (https://api.xxx:6443): " url
    ocp-login --add "$name" "$url"
    echo ""
done
echo ""

echo -e "${GREEN}✓ Instalacja zakończona${NC}"
echo ""
echo "W nowej sesji (lub po: source ~/.bashrc):"
echo "  source ocp-activate"
echo "  ocp [klaster]"
