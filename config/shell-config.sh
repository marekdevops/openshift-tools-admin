#!/bin/bash
#
# OpenShift Tools - Konfiguracja Shell
# Dodaj do ~/.bashrc lub ~/.zshrc:
#   source /path/to/openshift-tools/config/shell-config.sh
#

# ============================================
# ŚCIEŻKI
# ============================================

# Katalog z narzędziami OCP
export OCP_TOOLS_DIR="${OCP_TOOLS_DIR:-$HOME/.local/share/openshift-tools}"

# Katalogi kubeconfig
export KUBE_CLUSTERS_DIR="$HOME/.kube/clusters"
export KUBE_TOKENS_DIR="$HOME/.kube/tokens"

# Dodaj bin do PATH
export PATH="$OCP_TOOLS_DIR/bin:$PATH"

# ============================================
# ALIASY - SZYBKIE PRZEŁĄCZANIE KLASTRÓW
# ============================================

# Dostosuj do swoich klastrów!
# Format: alias kNAZWA='export KUBECONFIG=~/.kube/clusters/NAZWA'

alias kprod1='export KUBECONFIG=$KUBE_CLUSTERS_DIR/prod-cluster1 && echo "🔴 PRODUKCJA 1"'
alias kprod2='export KUBECONFIG=$KUBE_CLUSTERS_DIR/prod-cluster2 && echo "🔴 PRODUKCJA 2"'
alias kstg='export KUBECONFIG=$KUBE_CLUSTERS_DIR/staging-cluster && echo "🟡 STAGING"'
alias kdev='export KUBECONFIG=$KUBE_CLUSTERS_DIR/dev-cluster && echo "🟢 DEV"'
alias ktest='export KUBECONFIG=$KUBE_CLUSTERS_DIR/test-cluster && echo "🔵 TEST"'

# Reset KUBECONFIG
alias kreset='unset KUBECONFIG && echo "KUBECONFIG reset"'

# ============================================
# ALIASY - KOMENDY OC
# ============================================

# Podstawowe
alias k='oc'
alias kgp='oc get pods'
alias kgs='oc get services'
alias kgd='oc get deployments'
alias kgn='oc get nodes'
alias kgpv='oc get pv'
alias kgpvc='oc get pvc'

# Projekty/Namespaces
alias kgns='oc get projects'
alias kns='oc project'

# Describe
alias kdp='oc describe pod'
alias kds='oc describe service'
alias kdd='oc describe deployment'
alias kdn='oc describe node'

# Logs
alias kl='oc logs'
alias klf='oc logs -f'

# Exec
alias kexec='oc exec -it'

# Delete
alias kdel='oc delete'

# Apply
alias ka='oc apply -f'

# Status klastra
alias kinfo='echo "=== Cluster Info ===" && oc cluster-info && echo "" && echo "=== User ===" && oc whoami && echo "" && echo "=== Project ===" && oc project'

# ============================================
# ALIASY - BEZPIECZEŃSTWO PRODUKCJI
# ============================================

# Funkcja sprawdzająca czy jesteśmy na produkcji
__is_prod() {
    if [[ "$KUBECONFIG" == *"prod"* ]]; then
        return 0
    fi
    return 1
}

# Bezpieczne delete - wymaga potwierdzenia na produkcji
safe_delete() {
    if __is_prod; then
        echo -e "\033[0;31m⚠️  UWAGA: Jesteś na środowisku PRODUKCYJNYM!\033[0m"
        echo "Komenda: oc delete $@"
        read -p "Czy na pewno chcesz kontynuować? (tak/nie): " confirm
        if [[ "$confirm" == "tak" ]]; then
            oc delete "$@"
        else
            echo "Anulowano."
        fi
    else
        oc delete "$@"
    fi
}

alias kdelete='safe_delete'

# ============================================
# WALIDACJA TOKENU
# ============================================

__check_token_validity() {
    local kubeconfig_file="$1"

    if [[ ! -f "$kubeconfig_file" ]]; then
        echo "missing"
        return
    fi

    local token=$(grep "token:" "$kubeconfig_file" 2>/dev/null | head -1 | awk '{print $2}')

    if [[ -z "$token" ]]; then
        echo "no-token"
        return
    fi

    # Sprawdź JWT expiration
    if [[ "$token" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
        local payload=$(echo "$token" | cut -d. -f2 | base64 -d 2>/dev/null)
        local exp=$(echo "$payload" | grep -o '"exp":[0-9]*' 2>/dev/null | cut -d: -f2)

        if [[ -n "$exp" ]]; then
            local now=$(date +%s)
            if [[ $exp -lt $now ]]; then
                echo "expired"
                return
            fi
        fi
    fi

    echo "valid"
}

# ============================================
# FUNKCJE POMOCNICZE
# ============================================

# Pokaż aktualny kontekst z informacją o tokenie
ocp-current() {
    if [[ -z "$KUBECONFIG" ]]; then
        echo -e "\033[0;31mKUBECONFIG: nie ustawiony\033[0m"
        echo -e "\033[0;33mUWAGA: Komendy oc/kubectl użyją ~/.kube/config!\033[0m"
        return 1
    fi

    echo "KUBECONFIG: $KUBECONFIG"

    # Status tokenu
    local token_status=$(__check_token_validity "$KUBECONFIG")
    case "$token_status" in
        valid)    echo -e "Token:      \033[0;32maktywny\033[0m" ;;
        expired)  echo -e "Token:      \033[0;31mWYGASŁ\033[0m" ;;
        no-token) echo -e "Token:      \033[0;33mbrak\033[0m" ;;
        *)        echo -e "Token:      \033[0;90mnieznany\033[0m" ;;
    esac

    local user=$(oc whoami 2>/dev/null)
    if [[ -n "$user" ]]; then
        echo -e "User:       \033[0;32m$user\033[0m"
        echo "Project:    $(oc project -q 2>/dev/null || echo 'brak')"
        echo "API:        $(oc whoami --show-server 2>/dev/null)"
    else
        echo -e "User:       \033[0;31mnie zalogowany\033[0m"
    fi
}

# Lista wszystkich klastrów ze statusem tokenów
ocp-list() {
    echo "Dostępne klastry:"

    if [[ ! -d "$KUBE_CLUSTERS_DIR" ]] || [[ -z "$(ls -A "$KUBE_CLUSTERS_DIR" 2>/dev/null)" ]]; then
        echo "  (brak skonfigurowanych)"
        return
    fi

    for cluster in "$KUBE_CLUSTERS_DIR"/*; do
        if [[ -f "$cluster" ]]; then
            local name=$(basename "$cluster")
            local status=$(__check_token_validity "$cluster")
            local marker="  "
            [[ "$KUBECONFIG" == "$cluster" ]] && marker="* "

            case "$status" in
                valid)    echo -e "${marker}$name  \033[0;32m[OK]\033[0m" ;;
                expired)  echo -e "${marker}$name  \033[0;31m[WYGASŁ]\033[0m" ;;
                *)        echo -e "${marker}$name  \033[0;90m[?]\033[0m" ;;
            esac
        fi
    done

    echo ""
    echo "Aktualny: ${KUBECONFIG:-brak}"
}

# Sprawdź wszystkie tokeny
ocp-check() {
    echo -e "\033[0;34m=== Status tokenów ===\033[0m"
    echo ""

    if [[ ! -d "$KUBE_CLUSTERS_DIR" ]] || [[ -z "$(ls -A "$KUBE_CLUSTERS_DIR" 2>/dev/null)" ]]; then
        echo "Brak skonfigurowanych klastrów."
        return
    fi

    for cluster in "$KUBE_CLUSTERS_DIR"/*; do
        if [[ -f "$cluster" ]]; then
            local name=$(basename "$cluster")
            local status=$(__check_token_validity "$cluster")
            local api=$(grep "server:" "$cluster" 2>/dev/null | head -1 | awk '{print $2}')

            case "$status" in
                valid)   echo -e "\033[0;32m[OK]\033[0m      $name → $api" ;;
                expired) echo -e "\033[0;31m[WYGASŁ]\033[0m  $name → $api" ;;
                *)       echo -e "\033[0;90m[?]\033[0m       $name → $api" ;;
            esac
        fi
    done
}

# Przełącz klaster (wrapper z auto-login)
ocp() {
    if [[ -z "$1" ]]; then
        ocp-list
    else
        source ocp-switch "$1"
    fi
}

# ============================================
# PROMPT BEZ STARSHIP (alternatywa)
# ============================================

# Odkomentuj jeśli nie używasz Starship
# __kube_ps1() {
#     local ctx=""
#     local ns=""
#
#     if [[ -n "$KUBECONFIG" ]]; then
#         ctx=$(basename "$KUBECONFIG" 2>/dev/null)
#         ns=$(oc project -q 2>/dev/null)
#     fi
#
#     if [[ -n "$ctx" ]]; then
#         local color="\033[0;33m"  # żółty domyślnie
#
#         case "$ctx" in
#             *prod*)  color="\033[0;31m" ;;  # czerwony
#             *dev*)   color="\033[0;32m" ;;  # zielony
#             *stag*)  color="\033[0;33m" ;;  # żółty
#             *test*)  color="\033[0;34m" ;;  # niebieski
#         esac
#
#         echo -e "${color}[${ctx}/${ns:-default}]\033[0m "
#     fi
# }
#
# # Dla Bash
# PS1='$(__kube_ps1)\u@\h:\w\$ '
#
# # Dla Zsh
# # PROMPT='$(__kube_ps1)%n@%m:%~%# '

# ============================================
# STARSHIP (rekomendowane)
# ============================================

# Inicjalizacja Starship (jeśli zainstalowany)
if command -v starship &> /dev/null; then
    eval "$(starship init bash)"  # lub zsh
fi

# ============================================
# AUTOUZUPEŁNIANIE
# ============================================

# Autouzupełnianie dla oc (jeśli dostępne)
if command -v oc &> /dev/null; then
    source <(oc completion bash 2>/dev/null) || true
fi

# Autouzupełnianie dla kubectl (jeśli używasz)
if command -v kubectl &> /dev/null; then
    source <(kubectl completion bash 2>/dev/null) || true
fi

# Autouzupełnianie dla ocp-switch
_ocp_switch_completions() {
    local clusters=$(ls "$KUBE_CLUSTERS_DIR" 2>/dev/null)
    COMPREPLY=($(compgen -W "$clusters" -- "${COMP_WORDS[1]}"))
}
complete -F _ocp_switch_completions ocp-switch
complete -F _ocp_switch_completions ocp

# ============================================
# INFO NA STARCIE
# ============================================

# Pokaż aktualny klaster przy starcie sesji (opcjonalne)
# ocp-current
