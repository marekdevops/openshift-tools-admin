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
# FUNKCJE POMOCNICZE
# ============================================

# Pokaż aktualny kontekst
ocp-current() {
    echo "KUBECONFIG: ${KUBECONFIG:-nie ustawiony}"
    if [[ -n "$KUBECONFIG" ]]; then
        echo "User:       $(oc whoami 2>/dev/null || echo 'nie zalogowany')"
        echo "Project:    $(oc project -q 2>/dev/null || echo 'brak')"
        echo "API:        $(oc whoami --show-server 2>/dev/null || echo 'nieznany')"
    fi
}

# Lista wszystkich klastrów
ocp-list() {
    echo "Dostępne klastry:"
    ls -1 "$KUBE_CLUSTERS_DIR" 2>/dev/null || echo "Brak skonfigurowanych klastrów"
    echo ""
    echo "Aktualny: ${KUBECONFIG:-brak}"
}

# Przełącz klaster (wrapper)
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
