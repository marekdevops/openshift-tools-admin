#!/bin/bash
#
# ocp-common.sh - Wspólne funkcje dla narzędzi openshift-tools
#
# Wczytywane przez skrypty z bin/ (source). Nie uruchamiać bezpośrednio.
#

KUBE_CLUSTERS_DIR="${KUBE_CLUSTERS_DIR:-$HOME/.kube/clusters}"
OCP_CONFIG_DIR="${OCP_CONFIG_DIR:-$HOME/.config/openshift-tools}"
OCP_CONFIG_FILE="$OCP_CONFIG_DIR/config"

# Timeout (sekundy) dla zapytań sprawdzających klaster
OCP_TIMEOUT="${OCP_TIMEOUT:-5}"

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ============================================
# KONFIGURACJA
# ============================================

# Wczytaj OCP_USER i OCP_CA_FILE z pliku konfiguracyjnego.
# Plik jest parsowany (KLUCZ=wartość), nie wykonywany.
# Zmienne ustawione w środowisku mają pierwszeństwo.
ocp_load_config() {
    [[ -f "$OCP_CONFIG_FILE" ]] || return 0

    local key value
    while IFS='=' read -r key value; do
        value="${value%\"}"
        value="${value#\"}"
        case "$key" in
            OCP_USER)    [[ -z "$OCP_USER" ]] && OCP_USER="$value" ;;
            OCP_CA_FILE) [[ -z "$OCP_CA_FILE" ]] && OCP_CA_FILE="${value/#\~/$HOME}" ;;
        esac
    done < <(grep -E '^[A-Z_]+=' "$OCP_CONFIG_FILE")
}

# Zapisz klucz w pliku konfiguracyjnym (podmienia istniejącą wartość)
ocp_save_config() {
    local key="$1"
    local value="$2"

    mkdir -p "$OCP_CONFIG_DIR"
    chmod 700 "$OCP_CONFIG_DIR"
    touch "$OCP_CONFIG_FILE"
    chmod 600 "$OCP_CONFIG_FILE"

    local tmp
    tmp=$(mktemp "$OCP_CONFIG_FILE.XXXXXX") || return 1
    grep -v "^$key=" "$OCP_CONFIG_FILE" > "$tmp"
    echo "$key=\"$value\"" >> "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$OCP_CONFIG_FILE"
}

# ============================================
# KLASTRY
# ============================================

# Nazwa klastra = nazwa pliku w KUBE_CLUSTERS_DIR; blokuje ../ i ukryte pliki
ocp_valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

ocp_cluster_file() {
    echo "$KUBE_CLUSTERS_DIR/$1"
}

# Nazwy skonfigurowanych klastrów (bez archiwum i plików tymczasowych)
ocp_cluster_names() {
    local f
    for f in "$KUBE_CLUSTERS_DIR"/*; do
        [[ -f "$f" ]] && basename "$f"
    done
}

# API URL z kubeconfig (z bieżącego kontekstu)
ocp_cluster_server() {
    oc config view --kubeconfig="$1" --minify \
        -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null
}

# Namespace bieżącego kontekstu (lokalnie, bez połączenia z klastrem)
ocp_cluster_namespace() {
    oc config view --kubeconfig="$1" --minify \
        -o jsonpath='{.contexts[0].context.namespace}' 2>/dev/null
}

ocp_is_prod() {
    [[ "$1" == *prod* ]]
}

# ============================================
# STATUS SESJI
# ============================================

# Sprawdź sesję w kubeconfig przez API klastra.
# Wynik: ok:<użytkownik> | expired | no-token | unreachable | missing
#
# Tokeny OAuth użytkownika (sha256~...) nie są JWT - ich ważności nie da się
# sprawdzić lokalnie, więc zawsze pytamy API.
ocp_session_status() {
    local kubeconfig="$1"

    if [[ ! -f "$kubeconfig" ]]; then
        echo "missing"
        return
    fi

    if ! grep -q '^ *token: *[^ ]' "$kubeconfig"; then
        echo "no-token"
        return
    fi

    local out
    out=$(oc whoami --kubeconfig="$kubeconfig" --request-timeout="${OCP_TIMEOUT}s" 2>&1)

    if [[ $? -eq 0 ]]; then
        echo "ok:$out"
    elif [[ "$out" == *Unauthorized* || "$out" == *"must be logged in"* ]]; then
        echo "expired"
    else
        echo "unreachable"
    fi
}

# Status czytelny dla człowieka
ocp_format_status() {
    local status="$1"

    case "$status" in
        ok:*)
            local user="${status#ok:}"
            if [[ -n "$OCP_USER" && "$user" != "$OCP_USER" ]]; then
                echo -e "${YELLOW}inne konto: $user${NC}"
            else
                echo -e "${GREEN}zalogowany${NC} ${GRAY}($user)${NC}"
            fi
            ;;
        expired)     echo -e "${RED}sesja wygasła${NC}" ;;
        no-token)    echo -e "${GRAY}niezalogowany${NC}" ;;
        unreachable) echo -e "${YELLOW}niedostępny${NC}" ;;
        missing)     echo -e "${RED}brak pliku kubeconfig${NC}" ;;
        *)           echo -e "${GRAY}nieznany${NC}" ;;
    esac
}

# Czy sesja jest ważna i należy do skonfigurowanego użytkownika
ocp_session_is_mine() {
    local status="$1"
    [[ "$status" == ok:* ]] || return 1
    [[ -z "$OCP_USER" || "${status#ok:}" == "$OCP_USER" ]]
}

# ============================================
# TLS
# ============================================

# Sprawdź, czy certyfikat API i serwera OAuth jest zaufany.
# Hasło AD nie może trafić do serwera bez weryfikacji certyfikatu.
ocp_check_tls() {
    local server="$1"
    local ca_args=()
    [[ -n "$OCP_CA_FILE" ]] && ca_args=(--cacert "$OCP_CA_FILE")

    local meta rc
    meta=$(curl -sS --max-time "$OCP_TIMEOUT" "${ca_args[@]}" \
        "$server/.well-known/oauth-authorization-server" 2>&1)
    rc=$?

    if [[ $rc -eq 60 || $rc -eq 35 || $rc -eq 77 ]]; then
        echo -e "${RED}Certyfikat API ($server) nie jest zaufany${NC}"
        _ocp_tls_hint
        return 1
    elif [[ $rc -ne 0 ]]; then
        echo -e "${RED}Nie można połączyć z $server${NC}"
        echo "  $meta"
        return 1
    fi

    local issuer
    issuer=$(echo "$meta" | grep -o '"issuer": *"[^"]*"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
    if [[ -z "$issuer" ]]; then
        echo -e "${RED}Serwer nie zwrócił adresu OAuth - czy to na pewno API OpenShift?${NC}"
        return 1
    fi

    curl -sS -o /dev/null --max-time "$OCP_TIMEOUT" "${ca_args[@]}" "$issuer/healthz" 2>/dev/null
    rc=$?
    if [[ $rc -eq 60 || $rc -eq 35 || $rc -eq 77 ]]; then
        echo -e "${RED}Certyfikat serwera OAuth ($issuer) nie jest zaufany${NC}"
        _ocp_tls_hint
        return 1
    elif [[ $rc -ne 0 ]]; then
        echo -e "${RED}Nie można połączyć z serwerem OAuth ($issuer)${NC}"
        return 1
    fi

    return 0
}

_ocp_tls_hint() {
    if [[ -n "$OCP_CA_FILE" ]]; then
        echo "  Używany CA: $OCP_CA_FILE"
        echo "  Sprawdź, czy plik zawiera firmowe CA (także pośrednie)."
    else
        echo "  Firmowe CA nie jest w systemowym magazynie zaufania."
        echo "  Wskaż plik CA: ocp-login --set-ca /ścieżka/do/firmowe-ca.pem"
    fi
    echo "  Logowanie przerwane - hasło nie zostało wysłane."
}

# ============================================
# LOGOWANIE
# ============================================

# Zaloguj użytkownika OCP_USER do klastra.
# oc sam pyta o hasło (ukryte), hasło nie przechodzi przez skrypt.
# Logowanie idzie do pliku tymczasowego - dotychczasowy kubeconfig
# zostaje nietknięty, jeśli logowanie się nie powiedzie.
ocp_login_cluster() {
    local name="$1"
    local server="$2"
    local cluster_file
    cluster_file=$(ocp_cluster_file "$name")

    if [[ -z "$OCP_USER" ]]; then
        echo -e "${RED}Brak skonfigurowanego użytkownika (OCP_USER)${NC}"
        echo "Ustaw: ocp-login --set-user [login]"
        return 1
    fi

    if [[ -z "$server" ]]; then
        server=$(ocp_cluster_server "$cluster_file")
    fi
    if [[ -z "$server" ]]; then
        echo -e "${RED}Brak API URL dla klastra '$name'${NC}"
        return 1
    fi

    ocp_check_tls "$server" || return 1

    local namespace=""
    [[ -f "$cluster_file" ]] && namespace=$(ocp_cluster_namespace "$cluster_file")

    local tmp
    tmp=$(mktemp "$KUBE_CLUSTERS_DIR/.login-$name.XXXXXX") || return 1

    local ca_args=()
    [[ -n "$OCP_CA_FILE" ]] && ca_args=(--certificate-authority="$OCP_CA_FILE")

    echo -e "${BLUE}Logowanie do $name jako $OCP_USER${NC} ${GRAY}($server)${NC}"

    # stdout nie jest przekierowany - oc wypisuje na nim pytanie o hasło
    if ! oc login "$server" -u "$OCP_USER" --kubeconfig="$tmp" "${ca_args[@]}"; then
        rm -f "$tmp"
        echo -e "${RED}Logowanie do $name nie powiodło się${NC}"
        return 1
    fi

    # Kontekst nazwany jak klaster (starship, prompt), przywróć namespace
    local ctx
    ctx=$(oc config current-context --kubeconfig="$tmp")
    if [[ "$ctx" != "$name" ]]; then
        oc config rename-context "$ctx" "$name" --kubeconfig="$tmp" >/dev/null
    fi
    if [[ -n "$namespace" ]]; then
        oc config set-context "$name" --namespace="$namespace" --kubeconfig="$tmp" >/dev/null
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$cluster_file"

    echo -e "${GREEN}Zalogowano do $name${NC}"
}

# Unieważnij token na klastrze i usuń go z kubeconfig
ocp_logout_cluster() {
    local name="$1"
    local cluster_file
    cluster_file=$(ocp_cluster_file "$name")

    if ! grep -q '^ *token: *[^ ]' "$cluster_file" 2>/dev/null; then
        echo -e "  $name: ${GRAY}niezalogowany${NC}"
        return 0
    fi

    if oc logout --kubeconfig="$cluster_file" --request-timeout="${OCP_TIMEOUT}s" &>/dev/null; then
        echo -e "  $name: ${GREEN}wylogowano (token unieważniony)${NC}"
    else
        # Klaster niedostępny - usuń token przynajmniej lokalnie
        sed -i '/^ *token: /d' "$cluster_file"
        echo -e "  $name: ${YELLOW}klaster niedostępny - token usunięty tylko lokalnie${NC}"
    fi
}

ocp_load_config
