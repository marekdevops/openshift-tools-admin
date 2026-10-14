# OpenShift Tools - Instrukcja

Narzędzia do pracy z wieloma klastrami OpenShift **na własnym koncie LDAP/AD**.
Każda operacja na klastrze jest wykonywana jako Twój użytkownik, więc audit logi
klastra pokazują, kto co zrobił. Nie ma wspólnego konta ServiceAccount ani tokenów, które nie wygasają.

## Jak to działa

```
source ocp-activate        → wejście do środowiska, wczytanie loginu AD
ocp klaster1               → przełączenie; jeśli sesja wygasła - pytanie o hasło AD
ocp klaster2               → j.w.
ocp-deactivate             → wyjście
```

- Każdy klaster to osobny plik kubeconfig: `~/.kube/clusters/<nazwa>`.
- Logowanie: `oc login -u <Twój login>`. Hasło wpisujesz bezpośrednio do `oc`,
  skrypty go nie widzą i nigdzie nie zapisują.
- Token sesji OAuth jest ważny zwykle 24h. Po wygaśnięciu `ocp klaster`
  poprosi o hasło ponownie. Kubeconfigi są wspólne dla wszystkich terminali
  i okien tmux, więc wystarczy zalogować się raz.
- Hasło jest wysyłane **tylko** do serwerów z zaufanym certyfikatem (firmowe CA).
  Jeśli certyfikat się nie zgadza, logowanie jest przerywane przed pytaniem o hasło.

## Zawartość

```
openshift-tools/
├── install.sh                    # Instalacja i pierwsza konfiguracja
├── bin/
│   ├── ocp-activate              # Wejście do środowiska (source)
│   ├── ocp-login                 # Logowanie, dodawanie klastrów, konfiguracja
│   ├── ocp-remove                # Archiwizacja/usuwanie klastrów
│   ├── ocp-tmux                  # Sesja tmux z oknem na klaster
│   ├── tmux-ocp-status           # Kolorowy klaster w statusline tmux
│   ├── tmux-ocp-popup            # Popupy tmux (Prefix+o, Prefix+O)
│   └── migrate-configuration.sh  # Przeniesienie konfiguracji na inną maszynę
├── lib/
│   └── ocp-common.sh             # Wspólne funkcje
├── config/
│   ├── starship.toml             # Prompt Starship (opcjonalnie)
│   ├── tmux.conf                 # Pełna konfiguracja tmux (opcjonalnie)
│   └── tmux-ocp-addon.conf       # Dodatek do istniejącego tmux.conf
└── downloads/                    # Binaria do instalacji offline
```

---

## 1. Instalacja

### 1.1 Wymagania

- `oc` (OpenShift CLI) w `PATH` lub w `~/.local/bin`
- `curl`, `bash` 4+
- opcjonalnie: `tmux` (≥ 3.2 dla popupów), `starship`, `fzf`

Na hoście bez internetu skopiuj paczkę i rozpakuj binaria z `downloads/`:

```bash
scp -r openshift-tools/ user@bastion:/tmp/
ssh user@bastion

mkdir -p ~/.local/bin
cd /tmp/openshift-tools/downloads
tar -xzf starship-x86_64-unknown-linux-gnu.tar.gz -C ~/.local/bin/   # opcjonalnie
tar -xzf kubectx_v0.9.5_linux_x86_64.tar.gz -C ~/.local/bin/          # opcjonalnie
tar -xzf kubens_v0.9.5_linux_x86_64.tar.gz -C ~/.local/bin/           # opcjonalnie
```

### 1.2 Firmowe CA

Certyfikaty API (`api.*:6443`) i serwera logowania (`oauth-openshift.apps.*`)
są podpisane firmowym CA. Narzędzia muszą temu CA ufać. Są dwie możliwości:

- **CA jest w systemowym magazynie** (`/etc/pki/ca-trust/`): nic nie trzeba robić.
  Sprawdzenie: `curl -sS https://api.KLASTER:6443/version` działa bez `-k`.
- **CA jako plik PEM**: podaj go przy instalacji. Zostanie skopiowany do
  `~/.config/openshift-tools/ca-bundle.pem`. Jeśli jest CA pośrednie, plik
  powinien zawierać cały łańcuch (kilka bloków `BEGIN CERTIFICATE`).

### 1.3 Uruchom instalator

```bash
cd /tmp/openshift-tools
./install.sh
```

Instalator:

1. sprawdza wymagania,
2. kopiuje narzędzia do `~/.local/share/openshift-tools` i dodaje je do `PATH` w `~/.bashrc`,
3. pyta o **login LDAP/AD** i zapisuje go w `~/.config/openshift-tools/config`,
4. pyta o plik **firmowego CA** (Enter = systemowy magazyn),
5. kopiuje `starship.toml`, jeśli go jeszcze nie masz,
6. pozwala od razu **dodać klastry** (nazwa + API URL); każdy klaster jest od razu testowany logowaniem.

Bez pytań: `./install.sh --user jan.kowalski --ca /ścieżka/firmowe-ca.pem`

Potem otwórz nową sesję albo wykonaj `source ~/.bashrc`.

### 1.4 Aktualizacja

Uruchom `./install.sh` z nowej wersji paczki. Konfiguracja i klastry zostają.

---

## 2. Codzienna praca

```bash
source ocp-activate            # wejście, pokazuje skonfigurowany login
ocp                            # lista klastrów ze statusem sesji
ocp prod-cluster1              # przełączenie (+ logowanie, jeśli trzeba)
ocp dev-cluster                # j.w.
ocp-current                    # szczegóły aktualnego klastra
ocp-deactivate                 # wyjście
```

`source ocp-activate prod-cluster1` aktywuje środowisko i od razu przełącza na klaster.
Nazwy klastrów podpowiada `Tab`.

Przykładowa sesja:

```
$ source ocp-activate
✓ Środowisko OpenShift aktywowane
  Użytkownik: jan.kowalski

(ocp) $ ocp prod-cluster1
Przełączono na: prod-cluster1
Logowanie do prod-cluster1 jako jan.kowalski (https://api.prod1.example.com:6443)
Authentication required for https://api.prod1.example.com:6443 (openshift)
Username: jan.kowalski
Password:
Login successful.
Zalogowano do prod-cluster1
⚠️  UWAGA: Środowisko PRODUKCYJNE!

[prod-cluster1/default] $ ocp
Klastry (użytkownik: jan.kowalski)
* prod-cluster1            zalogowany (jan.kowalski)
  dev-cluster              sesja wygasła
  test-cluster             niedostępny
```

Statusy sesji:

| Status | Znaczenie | Co zrobi `ocp klaster` |
|---|---|---|
| `zalogowany` | ważna sesja Twojego konta | tylko przełączy |
| `sesja wygasła` | token wygasł lub został unieważniony | zapyta o hasło |
| `niezalogowany` | brak sesji (nowy klaster, po wylogowaniu, po migracji) | zapyta o hasło |
| `inne konto: …` | kubeconfig ma sesję innego konta (np. starego SA) | zaloguje Twoim kontem |
| `niedostępny` | brak połączenia (sieć, VPN, klaster) | tylko przełączy |

### Wylogowanie

```bash
ocp-logout                     # aktualny klaster
ocp-logout dev-cluster         # wybrany klaster
ocp-logout --all               # wszystkie
ocp-deactivate --logout        # wyjście + wylogowanie ze wszystkich
```

Wylogowanie **unieważnia token na klastrze**, a nie tylko usuwa go lokalnie.
Warto to robić na koniec dnia na współdzielonych hostach.

### Wymuszenie ponownego logowania

```bash
ocp-login prod-cluster1
```

---

## 3. Zarządzanie klastrami

### Dodanie klastra

```bash
ocp-add prod-cluster1 https://api.prod1.example.com:6443
# poza aktywnym środowiskiem:
ocp-login --add prod-cluster1 https://api.prod1.example.com:6443
```

Nazwa jest dowolna (litery, cyfry, `.`, `_`, `-`). Nazwa zawierająca `prod`
daje czerwony prompt i ostrzeżenie, `stag` żółty, `dev` zielony, `test` niebieski.

### Usunięcie nieużywanego klastra z listy

```bash
ocp-remove stary-klaster              # archiwizacja (znika z listy)
ocp-remove --list                     # zarchiwizowane
ocp-remove --restore stary-klaster    # przywrócenie
ocp-remove --delete stary-klaster     # wylogowanie + trwałe usunięcie
```

`--delete` robi backup (bez tokenu) w `~/.kube/backup-<data>/`.

### Konfiguracja

```bash
ocp-login --config                    # pokaż
ocp-login --set-user jan.kowalski     # zmień login
ocp-login --set-ca ~/firmowe-ca.pem   # zmień CA
ocp-login --set-ca none               # użyj systemowego magazynu
```

Plik: `~/.config/openshift-tools/config`. Zmienne środowiskowe `OCP_USER`
i `OCP_CA_FILE` mają pierwszeństwo przed plikiem.

---

## 4. tmux (opcjonalnie)

```bash
ocp-tmux                       # sesja z oknem na każdy klaster
ocp-tmux prod-cluster1 dev     # tylko wybrane
ocp-tmux -a                    # dołącz do istniejącej sesji
ocp-tmux -k                    # zamknij sesję
```

`ocp-tmux` najpierw loguje (w bieżącym terminalu) do klastrów z wygasłą sesją,
dopiero potem otwiera okna. Okna nie pytają więc o hasło jednocześnie.

Konfiguracja tmux - jedna z opcji:

```bash
# pełna konfiguracja
cp ~/.local/share/openshift-tools/config/tmux.conf ~/.tmux.conf
# albo dodatek do istniejącej
echo "source-file ~/.local/share/openshift-tools/config/tmux-ocp-addon.conf" >> ~/.tmux.conf
```

Statusline pokazuje klaster **bieżącego okna** (opcja okna `@ocp_cluster`,
ustawiana przez `ocp`). Skróty: `Prefix+o` informacje o klastrze, `Prefix+O`
wybór klastra.

---

## 5. Prompt Starship (opcjonalnie)

`ocp-activate` sam dodaje do promptu `[klaster/namespace]`. Jeśli wolisz
Starship, dodaj do `~/.bashrc`:

```bash
eval "$(starship init bash)"
```

Nazwa kontekstu w kubeconfig to nazwa klastra, więc aliasy w
`~/.config/starship.toml` (`[kubernetes.context_aliases]`) używają nazw klastrów.

---

## 6. Przeniesienie na inną maszynę

```bash
migrate-configuration.sh user@nowy-bastion.example.com
migrate-configuration.sh -n user@nowy-bastion.example.com   # podgląd
```

Przenoszone są: narzędzia, lista klastrów, login i CA (`~/.config/openshift-tools`),
`starship.toml` i binaria z `~/.local/bin`. **Tokeny sesji nie są przenoszone.**
Na nowej maszynie pierwsze `ocp klaster` poprosi o hasło.

---

## 7. Przejście z tokenów ServiceAccount (`ocp-admin-sa`)

Poprzednia wersja narzędzi logowała się wspólnym kontem `ocp-admin-sa` z rolą
`cluster-admin` i tokenem, który nie wygasał. Takie konto uniemożliwia rozliczalność
i narusza polityki bezpieczeństwa. Po przejściu na logowanie własnym kontem:

### 7.1 Lokalnie

1. Zainstaluj nową wersję (`./install.sh`). Istniejące pliki w `~/.kube/clusters/`
   zostają. `ocp` pokaże przy nich `inne konto: system:serviceaccount:...`, a pierwsze
   `ocp klaster` zaloguje Twoim kontem i nadpisze sesję SA.
2. Usuń stare tokeny i rejestr:
   ```bash
   rm -rf ~/.kube/tokens
   rm -f ~/.kube/cluster-registry.conf
   ```
3. Usuń z `~/.bashrc` wpisy `source .../shell-config.sh` i aliasy `kprod1` itp.
   (narzędzia `ocp-switch`, `ocp-create-sa-token`, `ocp-generate-kubeconfig`,
   `ocp-migrate` i `shell-config.sh` zostały usunięte; zastępuje je `ocp`).
4. Usuń stare kopie tokenów: `~/.kube/backup-*` z wcześniejszych migracji
   oraz kopie na innych maszynach.

### 7.2 Na każdym klastrze

Dopóki Secret z tokenem istnieje, token SA działa, także z każdej maszyny,
na którą został skopiowany. Po zalogowaniu własnym kontem:

```bash
oc delete clusterrolebinding ocp-admin-sa-cluster-admin
oc delete secret ocp-admin-sa-token -n openshift-config
oc delete serviceaccount ocp-admin-sa -n openshift-config
```

Sprawdzenie, że nic nie zostało:

```bash
oc get clusterrolebinding -o wide | grep ocp-admin-sa
oc get sa,secret -n openshift-config | grep ocp-admin-sa
```

### 7.3 Uprawnienia (do rozważenia)

Zasada najmniejszych uprawnień: na co dzień konto bez `cluster-admin`,
z rolą `sudoer`, a uprawnienia admina tylko gdy są potrzebne:

```bash
oc adm policy add-cluster-role-to-user sudoer jan.kowalski
oc delete pod xyz --as=system:admin
```

Audit log zapisuje wtedy i Twoje konto, i użycie uprawnień admina.

---

## Rozwiązywanie problemów

### „Certyfikat … nie jest zaufany”

Logowanie zostało przerwane, zanim padło pytanie o hasło. Sprawdź oba adresy:

```bash
curl -sS https://api.KLASTER:6443/version
curl -sS https://oauth-openshift.apps.KLASTER/healthz
# z plikiem CA:
curl -sS --cacert ~/.config/openshift-tools/ca-bundle.pem https://api.KLASTER:6443/version
```

Jeśli działa tylko z `--cacert`, ustaw: `ocp-login --set-ca PLIK`. Jeśli API ma
inne CA niż `*.apps` (np. wewnętrzne CA OpenShift), połącz oba w jednym pliku:
`cat firmowe-ca.pem api-ca.pem > ~/.config/openshift-tools/ca-bundle.pem`.

### „Login failed (401 Unauthorized)”

Błędne hasło albo konto nie ma dostępu do klastra (identity provider LDAP).
**Uwaga na blokadę konta AD** po kilku błędnych próbach.

### Klaster `niedostępny`

```bash
curl -sS https://api.KLASTER:6443/version     # sieć/VPN/DNS
```

Czas oczekiwania na odpowiedź: zmienna `OCP_TIMEOUT` (domyślnie 5 s).

### `oc` używa złego klastra / `system:anonymous`

Po `source ocp-activate` zmienna `KUBECONFIG` nie jest ustawiona, dopóki nie
wykonasz `ocp klaster`. Domyślny `~/.kube/config` jest celowo pusty, więc `oc`
bez wybranego klastra zgłasza błąd zamiast działać na przypadkowym klastrze.

---

## Bezpieczeństwo - podsumowanie

- Wszystkie operacje są wykonywane jako Twój użytkownik LDAP/AD, z pełną rozliczalnością w audit logach.
- Hasło trafia tylko do `oc` i nie jest zapisywane. Skrypty go nie widzą.
- Hasło jest wysyłane wyłącznie do serwerów z zaufanym certyfikatem.
- Tokeny sesji wygasają (domyślnie 24h), a `ocp-logout` unieważnia je na klastrze.
- Kubeconfigi mają uprawnienia `600`, a katalog `~/.kube/clusters` ma `700`.
- Tokeny nie są przenoszone przy migracji ani zapisywane w backupach `ocp-remove`.
