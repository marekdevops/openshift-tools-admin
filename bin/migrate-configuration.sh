#!/bin/bash
#
# migrate-configuration.sh - Przeniesienie całej konfiguracji OCP na inną maszynę
#
# Ten skrypt:
# - Pakuje narzędzia (bin/, config/), klastry, tokeny i rejestr klastrów
# - Wysyła paczkę przez scp i rozpakowuje ją na maszynie docelowej
# - Robi backup plików, które zostałyby nadpisane
# - Dodaje openshift-tools do PATH w ~/.bashrc na maszynie docelowej
#
# Po migracji na maszynie docelowej wystarczy: source ocp-activate
#

set -o pipefail

KUBE_DIR="${KUBE_CLUSTERS_DIR:-$HOME/.kube/clusters}"
TOKENS_DIR="${KUBE_TOKENS_DIR:-$HOME/.kube/tokens}"
CLUSTER_CONFIG="$HOME/.kube/cluster-registry.conf"
STARSHIP_CONFIG="$HOME/.config/starship.toml"
LOCAL_BIN="$HOME/.local/bin"

# Źródło narzędzi: katalog, z którego uruchomiono skrypt (instalacja lub repo)
SRC_TOOLS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# Ścieżki docelowe (względem $HOME na maszynie docelowej)
REMOTE_TOOLS_REL=".local/share/openshift-tools"

# Binarki przenoszone z ~/.local/bin (o ile istnieją)
BINARIES="oc kubectl kubectx kubens starship"

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
    echo "migrate-configuration.sh - Przeniesienie konfiguracji OCP na inną maszynę"
    echo ""
    echo "Użycie: migrate-configuration.sh [OPCJE] [user@]adres.maszyny.domena"
    echo ""
    echo "Opcje:"
    echo "  -p, --port PORT   Port SSH (domyślnie 22)"
    echo "  -n, --dry-run     Pokaż co zostanie przeniesione, nic nie wysyłaj"
    echo "  -y, --yes         Nie pytaj o potwierdzenie"
    echo "  --no-binaries     Nie przenoś binarek z ~/.local/bin"
    echo "  --no-bashrc       Nie modyfikuj ~/.bashrc na maszynie docelowej"
    echo "  -h, --help        Pokaż tę pomoc"
    echo ""
    echo "Przenoszone elementy:"
    echo "  $SRC_TOOLS_DIR/{bin,config}  → ~/$REMOTE_TOOLS_REL/"
    echo "  ~/.kube/clusters/            (kubeconfigi klastrów)"
    echo "  ~/.kube/tokens/              (tokeny)"
    echo "  ~/.kube/cluster-registry.conf"
    echo "  ~/.config/starship.toml"
    echo "  ~/.local/bin/{${BINARIES// /,}}"
    echo ""
    echo "Przykłady:"
    echo "  migrate-configuration.sh bastion.example.com"
    echo "  migrate-configuration.sh -n marek@bastion.example.com"
}

# ============================================
# ARGUMENTY
# ============================================

TARGET=""
SSH_PORT=""
DRY_RUN=0
ASSUME_YES=0
WITH_BINARIES=1
WITH_BASHRC=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)      SSH_PORT="$2"; shift 2 ;;
        -n|--dry-run)   DRY_RUN=1; shift ;;
        -y|--yes)       ASSUME_YES=1; shift ;;
        --no-binaries)  WITH_BINARIES=0; shift ;;
        --no-bashrc)    WITH_BASHRC=0; shift ;;
        -h|--help)      show_help; exit 0 ;;
        -*)
            echo -e "${RED}Nieznana opcja: $1${NC}"
            show_help
            exit 1
            ;;
        *)
            if [[ -n "$TARGET" ]]; then
                echo -e "${RED}Podano więcej niż jedną maszynę docelową${NC}"
                exit 1
            fi
            TARGET="$1"
            shift
            ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    show_help
    exit 1
fi

for cmd in ssh scp tar; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}Brak wymaganego polecenia: $cmd${NC}"
        exit 1
    fi
done

if [[ ! -f "$SRC_TOOLS_DIR/bin/ocp-activate" ]]; then
    echo -e "${RED}Nie znaleziono narzędzi w: $SRC_TOOLS_DIR${NC}"
    exit 1
fi

# ============================================
# PRZYGOTOWANIE PACZKI
# ============================================

umask 077
WORK_DIR=$(mktemp -d /tmp/ocp-migrate.XXXXXX) || exit 1
STAGE_DIR="$WORK_DIR/stage"
ARCHIVE="$WORK_DIR/ocp-configuration.tar.gz"

SSH_OPTS=(-o ControlMaster=auto -o ControlPath="$WORK_DIR/cm-%C" -o ControlPersist=60)
SCP_OPTS=("${SSH_OPTS[@]}")
if [[ -n "$SSH_PORT" ]]; then
    SSH_OPTS+=(-p "$SSH_PORT")
    SCP_OPTS+=(-P "$SSH_PORT")
fi

cleanup() {
    ssh "${SSH_OPTS[@]}" -O exit "$TARGET" &> /dev/null
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo -e "${BLUE}=== Migracja konfiguracji OCP → $TARGET ===${NC}"
echo ""

mkdir -p "$STAGE_DIR/$REMOTE_TOOLS_REL" "$STAGE_DIR/.kube"

# 1. Narzędzia
echo -e "${CYAN}1. Narzędzia ($SRC_TOOLS_DIR):${NC}"
for sub in bin config; do
    if [[ -d "$SRC_TOOLS_DIR/$sub" ]]; then
        cp -a "$SRC_TOOLS_DIR/$sub" "$STAGE_DIR/$REMOTE_TOOLS_REL/"
        echo -e "   ${GREEN}$sub/${NC} ($(ls "$SRC_TOOLS_DIR/$sub" | wc -l) plików)"
    fi
done
echo ""

# 2. Klastry
echo -e "${CYAN}2. Klastry ($KUBE_DIR):${NC}"
cluster_count=0
if [[ -d "$KUBE_DIR" ]]; then
    mkdir -p "$STAGE_DIR/.kube/clusters"
    for cluster in "$KUBE_DIR"/*; do
        if [[ -f "$cluster" ]]; then
            name=$(basename "$cluster")
            cp -a "$cluster" "$STAGE_DIR/.kube/clusters/"
            api=$(grep "server:" "$cluster" 2>/dev/null | head -1 | awk '{print $2}')
            echo -e "   ${GREEN}$name${NC}  $api"
            ((cluster_count++))

            # Ścieżki bezwzględne do $HOME nie zadziałają przy innym użytkowniku
            if grep -q "$HOME/" "$cluster" 2>/dev/null; then
                echo -e "   ${YELLOW}→ UWAGA: plik zawiera ścieżki do $HOME${NC}"
            fi
        fi
    done
fi
if [[ $cluster_count -eq 0 ]]; then
    echo -e "   ${YELLOW}(brak skonfigurowanych klastrów)${NC}"
fi
echo ""

# 3. Tokeny
echo -e "${CYAN}3. Tokeny ($TOKENS_DIR):${NC}"
token_count=0
if [[ -d "$TOKENS_DIR" ]]; then
    cp -a "$TOKENS_DIR" "$STAGE_DIR/.kube/tokens"
    token_count=$(find "$TOKENS_DIR" -type f | wc -l)
fi
echo "   Plików: $token_count"
echo ""

# 4. Rejestr klastrów
echo -e "${CYAN}4. Rejestr klastrów:${NC}"
if [[ -f "$CLUSTER_CONFIG" ]]; then
    cp -a "$CLUSTER_CONFIG" "$STAGE_DIR/.kube/"
    echo "   Wpisów: $(grep -c "^CLUSTER_API_" "$CLUSTER_CONFIG")"
else
    echo -e "   ${YELLOW}(brak $CLUSTER_CONFIG)${NC}"
fi
echo ""

# 5. Starship
echo -e "${CYAN}5. Konfiguracja starship:${NC}"
if [[ -f "$STARSHIP_CONFIG" ]]; then
    mkdir -p "$STAGE_DIR/.config"
    cp -a "$STARSHIP_CONFIG" "$STAGE_DIR/.config/"
    echo "   $STARSHIP_CONFIG"
else
    echo -e "   ${YELLOW}(brak $STARSHIP_CONFIG)${NC}"
fi
echo ""

# 6. Binarki
echo -e "${CYAN}6. Binarki ($LOCAL_BIN):${NC}"
binaries_staged=0
if [[ $WITH_BINARIES -eq 1 ]]; then
    for binary in $BINARIES; do
        if [[ -f "$LOCAL_BIN/$binary" ]]; then
            mkdir -p "$STAGE_DIR/.local/bin"
            cp -aL "$LOCAL_BIN/$binary" "$STAGE_DIR/.local/bin/"
            echo -e "   ${GREEN}$binary${NC}"
            ((binaries_staged++))
        fi
    done
    [[ $binaries_staged -eq 0 ]] && echo -e "   ${YELLOW}(brak binarek w $LOCAL_BIN)${NC}"
else
    echo "   (pominięto: --no-binaries)"
fi
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "${YELLOW}Tryb --dry-run: nic nie zostało wysłane${NC}"
    exit 0
fi

if [[ $ASSUME_YES -ne 1 ]]; then
    echo -e "${YELLOW}UWAGA: Tokeny dostępowe do klastrów zostaną skopiowane na $TARGET${NC}"
    read -p "Kontynuować? (t/n): " CONFIRM
    if [[ "$CONFIRM" != "t" ]]; then
        echo "Przerwano."
        exit 1
    fi
    echo ""
fi

# ============================================
# POŁĄCZENIE I WYSYŁKA
# ============================================

echo -e "${BLUE}=== Wysyłanie ===${NC}"

REMOTE_ARCH=$(ssh "${SSH_OPTS[@]}" "$TARGET" 'uname -sm')
if [[ $? -ne 0 || -z "$REMOTE_ARCH" ]]; then
    echo -e "${RED}Nie udało się połączyć z $TARGET${NC}"
    exit 1
fi

# Binarki mają sens tylko przy tej samej architekturze
if [[ $binaries_staged -gt 0 && "$REMOTE_ARCH" != "$(uname -sm)" ]]; then
    echo -e "${YELLOW}Inna architektura na $TARGET ($REMOTE_ARCH) - pomijam binarki${NC}"
    rm -rf "$STAGE_DIR/.local/bin"
fi

tar -czpf "$ARCHIVE" -C "$STAGE_DIR" . || exit 1
echo "Paczka: $(du -h "$ARCHIVE" | cut -f1)"

REMOTE_TMP=$(ssh "${SSH_OPTS[@]}" "$TARGET" 'umask 077 && mktemp -d /tmp/ocp-migrate.XXXXXX')
if [[ -z "$REMOTE_TMP" ]]; then
    echo -e "${RED}Nie udało się utworzyć katalogu tymczasowego na $TARGET${NC}"
    exit 1
fi

if ! scp -q "${SCP_OPTS[@]}" "$ARCHIVE" "$TARGET:$REMOTE_TMP/"; then
    echo -e "${RED}Błąd scp${NC}"
    ssh "${SSH_OPTS[@]}" "$TARGET" "rm -rf '$REMOTE_TMP'"
    exit 1
fi
echo -e "${GREEN}Wysłano${NC}"
echo ""

# ============================================
# INSTALACJA NA MASZYNIE DOCELOWEJ
# ============================================

echo -e "${BLUE}=== Instalacja na $TARGET ===${NC}"

ssh "${SSH_OPTS[@]}" "$TARGET" bash -s -- "$REMOTE_TMP" "$WITH_BASHRC" <<'REMOTE'
REMOTE_TMP="$1"
WITH_BASHRC="$2"
ARCHIVE="$REMOTE_TMP/ocp-configuration.tar.gz"
BACKUP_DIR="$HOME/.kube/backup-$(date +%Y%m%d-%H%M%S)"

umask 077
trap 'rm -rf "$REMOTE_TMP"' EXIT
cd "$HOME" || exit 1

# Backup plików, które zostaną nadpisane (poza narzędziami i binarkami)
backed_up=0
while read -r file; do
    file="${file#./}"
    case "$file" in
        .kube/*|.config/*)
            if [[ -f "$file" ]]; then
                mkdir -p "$BACKUP_DIR/$(dirname "$file")"
                cp -a "$file" "$BACKUP_DIR/$file"
                backed_up=$((backed_up + 1))
            fi
            ;;
    esac
done < <(tar -tzf "$ARCHIVE")
[[ $backed_up -gt 0 ]] && echo "Backup nadpisywanych plików ($backed_up): $BACKUP_DIR"

# --no-overwrite-dir: nie zmieniaj uprawnień istniejących katalogów (np. $HOME)
if ! tar -xzpf "$ARCHIVE" --no-overwrite-dir -C "$HOME"; then
    echo "BŁĄD: rozpakowanie paczki nie powiodło się"
    exit 1
fi

# Uprawnienia
chmod 700 .kube/clusters .kube/tokens 2>/dev/null
find .kube/clusters .kube/tokens -type f -exec chmod 600 {} + 2>/dev/null
chmod 755 .local .local/share .local/bin .local/share/openshift-tools \
    .local/share/openshift-tools/bin .local/share/openshift-tools/config 2>/dev/null
chmod 755 .local/share/openshift-tools/bin/* 2>/dev/null
chmod 644 .local/share/openshift-tools/config/* 2>/dev/null

echo "Klastry: $(find .kube/clusters -type f 2>/dev/null | wc -l)"

# PATH w ~/.bashrc - żeby 'source ocp-activate' działało od razu
if [[ "$WITH_BASHRC" == "1" ]]; then
    if ! grep -q "openshift-tools/bin" .bashrc 2>/dev/null; then
        {
            echo ""
            echo "# OpenShift tools"
            echo 'export PATH="$HOME/.local/bin:$HOME/.local/share/openshift-tools/bin:$PATH"'
        } >> .bashrc
        echo "Dodano openshift-tools do PATH w ~/.bashrc"
    else
        echo "PATH w ~/.bashrc już skonfigurowany"
    fi
fi

if [[ ! -x .local/bin/oc ]] && ! command -v oc &> /dev/null; then
    echo "UWAGA: brak polecenia 'oc' na tej maszynie - zainstaluj je ręcznie"
fi
REMOTE

if [[ $? -ne 0 ]]; then
    echo -e "${RED}Instalacja na $TARGET nie powiodła się${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Migracja zakończona${NC}"
echo ""
echo "Na maszynie $TARGET (w nowej sesji):"
echo "  source ocp-activate"
echo "  ocp-check"
