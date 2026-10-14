# OpenShift Tools - Instrukcja instalacji

Kompletny zestaw narzędzi do zarządzania wieloma klastrami OpenShift.

## Zawartość paczki

```
openshift-tools/
├── bin/                          # Skrypty
│   ├── ocp-activate              # Aktywacja środowiska (styl venv)
│   ├── ocp-switch                # Przełączanie między klastrami
│   ├── ocp-login                 # Logowanie do klastrów
│   ├── ocp-remove                # Usuwanie/archiwizacja klastrów z listy
│   ├── ocp-create-sa-token       # Tworzenie ServiceAccount z tokenem
│   └── ocp-generate-kubeconfig   # Generowanie plików kubeconfig
├── config/
│   ├── starship.toml             # Konfiguracja promptu Starship
│   └── shell-config.sh           # Aliasy i funkcje shell
├── downloads/                    # Binaria do instalacji offline
│   ├── kubectx_v0.9.5_linux_x86_64.tar.gz
│   ├── kubens_v0.9.5_linux_x86_64.tar.gz
│   └── starship-x86_64-unknown-linux-gnu.tar.gz
└── INSTALL.md                    # Ta instrukcja
```

---

## CZĘŚĆ 1: Instalacja na hoście przesiadkowym (offline)

### 1.1 Skopiuj paczkę na host

```bash
scp -r openshift-tools/ user@bastion-host:/tmp/
```

### 1.2 Zainstaluj na hoście

```bash
# Połącz się z hostem
ssh user@bastion-host

# Utwórz katalogi
mkdir -p ~/.local/share/openshift-tools/{bin,config}
mkdir -p ~/.local/bin
mkdir -p ~/.config
mkdir -p ~/.kube/{clusters,tokens}

# Skopiuj skrypty
cp /tmp/openshift-tools/bin/* ~/.local/share/openshift-tools/bin/
chmod +x ~/.local/share/openshift-tools/bin/*

# Skopiuj konfiguracje
cp /tmp/openshift-tools/config/* ~/.local/share/openshift-tools/config/

# Rozpakuj narzędzia
cd /tmp/openshift-tools/downloads

tar -xzf kubectx_v0.9.5_linux_x86_64.tar.gz -C ~/.local/bin/
tar -xzf kubens_v0.9.5_linux_x86_64.tar.gz -C ~/.local/bin/
tar -xzf starship-x86_64-unknown-linux-gnu.tar.gz -C ~/.local/bin/

# Sprawdź
ls -la ~/.local/bin/
```

### 1.3 Skonfiguruj shell

**OPCJA A: Aktywacja na żądanie (styl Python venv) - ZALECANE**

Dodaj tylko ścieżkę do `~/.bashrc`:

```bash
# OpenShift Tools - tylko PATH
export PATH="$HOME/.local/bin:$HOME/.local/share/openshift-tools/bin:$PATH"
```

Środowisko aktywujesz gdy potrzebujesz:

```bash
source ocp-activate           # aktywuj środowisko
source ocp-activate prod1     # aktywuj i przełącz na klaster

# Praca z OpenShift...

ocp-deactivate                # dezaktywuj gdy skończysz
```

**OPCJA B: Automatyczna aktywacja przy logowaniu**

Dodaj do `~/.bashrc` (lub `~/.zshrc`):

```bash
# OpenShift Tools
export OCP_TOOLS_DIR="$HOME/.local/share/openshift-tools"
export PATH="$HOME/.local/bin:$OCP_TOOLS_DIR/bin:$PATH"

# Załaduj konfigurację
source "$OCP_TOOLS_DIR/config/shell-config.sh"
```

### 1.4 Skonfiguruj Starship (opcjonalne, dla OPCJI B)

```bash
# Skopiuj konfigurację
cp ~/.local/share/openshift-tools/config/starship.toml ~/.config/starship.toml

# Dodaj do ~/.bashrc (na końcu pliku)
eval "$(starship init bash)"

# Dla zsh:
# eval "$(starship init zsh)"
```

### 1.5 Przeładuj shell

```bash
source ~/.bashrc
```

---

## CZĘŚĆ 2: Tworzenie nie wygasających tokenów (Service Account)

**WAŻNE:** Wykonaj te kroki na każdym klastrze, do którego chcesz mieć dostęp.

### 2.1 Zaloguj się do klastra jako cluster-admin

```bash
oc login https://api.KLASTER.example.com:6443 -u admin
```

### 2.2 Utwórz ServiceAccount z tokenem

**Metoda A: Użyj dostarczonego skryptu**

```bash
ocp-create-sa-token
```

Skrypt automatycznie:
- Utworzy ServiceAccount `ocp-admin-sa` w namespace `openshift-config`
- Nada mu uprawnienia `cluster-admin`
- Wygeneruje nie wygasający token
- Wyświetli token do skopiowania

**Metoda B: Ręcznie (jeśli wolisz)**

```bash
# 1. Utwórz ServiceAccount
oc create serviceaccount ocp-admin-sa -n openshift-config

# 2. Nadaj uprawnienia cluster-admin
oc adm policy add-cluster-role-to-user cluster-admin \
    system:serviceaccount:openshift-config:ocp-admin-sa

# 3. Utwórz Secret z tokenem (OCP 4.11+)
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ocp-admin-sa-token
  namespace: openshift-config
  annotations:
    kubernetes.io/service-account.name: ocp-admin-sa
type: kubernetes.io/service-account-token
EOF

# 4. Pobierz token (poczekaj 2-3 sekundy)
oc get secret ocp-admin-sa-token -n openshift-config \
    -o jsonpath='{.data.token}' | base64 -d && echo
```

### 2.3 Zapisz token

```bash
# Utwórz katalog na tokeny
mkdir -p ~/.kube/tokens
chmod 700 ~/.kube/tokens

# Zapisz token (zastąp NAZWA_KLASTRA)
echo 'TUTAJ_WKLEJ_TOKEN' > ~/.kube/tokens/NAZWA_KLASTRA
chmod 600 ~/.kube/tokens/NAZWA_KLASTRA
```

---

## CZĘŚĆ 3: Przygotowanie plików kubeconfig

### 3.1 Metoda A: Automatyczna (zalecana)

Po zalogowaniu się tokenem:

```bash
ocp-generate-kubeconfig prod-cluster1 https://api.prod1.example.com:6443
```

Skrypt poprosi o token i wygeneruje plik kubeconfig.

### 3.2 Metoda B: Ręczne tworzenie kubeconfig

Utwórz plik `~/.kube/clusters/NAZWA_KLASTRA`:

```yaml
apiVersion: v1
kind: Config
preferences: {}

clusters:
- cluster:
    server: https://api.KLASTER.example.com:6443
    insecure-skip-tls-verify: true
  name: NAZWA_KLASTRA

contexts:
- context:
    cluster: NAZWA_KLASTRA
    user: NAZWA_KLASTRA-admin
    namespace: default
  name: NAZWA_KLASTRA

current-context: NAZWA_KLASTRA

users:
- name: NAZWA_KLASTRA-admin
  user:
    token: TUTAJ_WKLEJ_CALY_TOKEN
```

Zastąp:
- `NAZWA_KLASTRA` - nazwa identyfikująca klaster (np. `prod-cluster1`)
- `https://api.KLASTER.example.com:6443` - URL API klastra
- `TUTAJ_WKLEJ_CALY_TOKEN` - token z kroku 2

```bash
chmod 600 ~/.kube/clusters/NAZWA_KLASTRA
```

### 3.3 Metoda C: Użycie oc login

```bash
# Zaloguj się i zapisz do osobnego pliku kubeconfig
oc login https://api.prod1.example.com:6443 \
    --token="$(cat ~/.kube/tokens/prod-cluster1)" \
    --kubeconfig=~/.kube/clusters/prod-cluster1
```

---

## CZĘŚĆ 4: Konfiguracja aliasów dla klastrów

Edytuj `~/.local/share/openshift-tools/config/shell-config.sh` i dostosuj aliasy:

```bash
# Zmień te linie na swoje klastry:
alias kprod1='export KUBECONFIG=$KUBE_CLUSTERS_DIR/prod-cluster1 && echo "🔴 PRODUKCJA 1"'
alias kprod2='export KUBECONFIG=$KUBE_CLUSTERS_DIR/prod-cluster2 && echo "🔴 PRODUKCJA 2"'
alias kstg='export KUBECONFIG=$KUBE_CLUSTERS_DIR/staging && echo "🟡 STAGING"'
alias kdev='export KUBECONFIG=$KUBE_CLUSTERS_DIR/dev && echo "🟢 DEV"'
```

Edytuj też `~/.config/starship.toml` - sekcję `[kubernetes.context_aliases]`:

```toml
[kubernetes.context_aliases]
"prod-cluster1" = "🔴 PROD-1"
"prod-cluster2" = "🔴 PROD-2"
"staging" = "🟡 STAGE"
"dev" = "🟢 DEV"
```

---

## CZĘŚĆ 5: Użytkowanie

### Przełączanie klastrów

```bash
# Lista dostępnych klastrów
ocp-switch

# Przełącz na klaster
source ocp-switch prod-cluster1

# Lub użyj aliasu
kprod1
kdev
kstg
```

### Usuwanie nieużywanych klastrów z listy

```bash
# Archiwizacja - klaster znika z listy, można go przywrócić
ocp-remove stary-klaster

# Lista zarchiwizowanych i przywrócenie
ocp-remove --list
ocp-remove --restore stary-klaster

# Trwałe usunięcie (kubeconfig, token, wpis w rejestrze; backup w ~/.kube/backup-*)
ocp-remove --delete stary-klaster
```

### Sprawdzanie aktualnego klastra

```bash
ocp-current
# lub
ocp-switch -c
```

### Prompt Starship

Po poprawnej konfiguracji, prompt będzie wyglądał tak:

```
☸ 🔴 PROD-1 (default) ~/projects/app
❯
```

Gdzie:
- `🔴 PROD-1` - nazwa klastra (czerwony = produkcja)
- `(default)` - aktualny namespace/projekt

---

## Rozwiązywanie problemów

### Token wygasł lub nie działa

```bash
# Sprawdź czy secret istnieje
oc get secret ocp-admin-sa-token -n openshift-config

# Jeśli nie, utwórz ponownie
ocp-create-sa-token

# Pobierz nowy token
oc get secret ocp-admin-sa-token -n openshift-config \
    -o jsonpath='{.data.token}' | base64 -d
```

### Starship nie pokazuje kontekstu

```bash
# Sprawdź czy KUBECONFIG jest ustawiony
echo $KUBECONFIG

# Sprawdź czy plik istnieje
ls -la $KUBECONFIG

# Sprawdź czy starship działa
starship --version
```

### Nie można połączyć się z klastrem

```bash
# Sprawdź połączenie sieciowe
curl -k https://api.KLASTER.example.com:6443/healthz

# Sprawdź token
oc whoami

# Sprawdź uprawnienia
oc auth can-i '*' '*' --all-namespaces
```

---

## Bezpieczeństwo

1. **Uprawnienia plików:**
   ```bash
   chmod 700 ~/.kube/tokens
   chmod 600 ~/.kube/tokens/*
   chmod 600 ~/.kube/clusters/*
   ```

2. **Rotacja tokenów** - jeśli podejrzewasz kompromitację:
   ```bash
   oc delete secret ocp-admin-sa-token -n openshift-config
   # Następnie utwórz nowy token
   ```

3. **Usunięcie dostępu:**
   ```bash
   oc delete serviceaccount ocp-admin-sa -n openshift-config
   oc delete clusterrolebinding ocp-admin-sa-cluster-admin
   ```
