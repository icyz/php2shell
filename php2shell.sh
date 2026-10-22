#!/usr/bin/env bash
# Ubuntu 22.04/24.04: aggiorna PHP della distribuzione e ricarica i servizi.
set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
mode=${1:---check} # Nessun argomento = solo controllo, senza modifiche.
if [[ $# -gt 1 || ( $mode != --check && $mode != --apply ) ]]; then
  echo "Uso: sudo bash $0 [--check|--apply]" >&2
  exit 1
fi
trap 'printf "ERRORE alla riga %s: operazione interrotta. Controllare i messaggi precedenti.\n" "$LINENO" >&2' ERR
versions_checked=0
needs_update=0
unknown_version=0
pending=0
apply_blocked=''
final_summary() {
  local status=$?
  echo
  echo "============================================================"
  echo "ESITO FINALE PHP2SHELL"
  if [[ $mode == --check ]]; then
    echo "Solo controllo: nessun aggiornamento o ricaricamento effettuato."
    if (( status != 0 && status != 2 )); then
      echo "VERIFICA INCOMPLETA: non è possibile decidere se aggiornare."
      echo "--apply: NON ESEGUIRE prima di risolvere l'errore indicato sopra."
    elif (( ! versions_checked || unknown_version )); then
      echo "VERIFICA MANUALE NECESSARIA: versione PHP non riconosciuta."
      echo "--apply: NON ESEGUIRE su questa configurazione."
    elif (( needs_update )); then
      echo "AGGIORNAMENTO NECESSARIO: mancano correzioni nei pacchetti PHP controllati."
      if [[ -n $apply_blocked ]]; then
        echo "--apply: NON UTILIZZABILE su questa configurazione."
        echo "Motivo: $apply_blocked"
        echo "Pianificare l'aggiornamento con una procedura dedicata."
      else
        echo "--apply: NECESSARIO per aggiornare con questo script."
        printf 'Comando: sudo bash %q --apply\n' "$0"
        echo "Pianificare una finestra: APT può riavviare servizi e interrompere richieste."
        echo "La disponibilità della correzione sarà verificata dopo apt update."
      fi
    else
      echo "AGGIORNAMENTO NON NECESSARIO per PHP2SHELL sui pacchetti controllati."
      echo "--apply: NON SERVE. La versione corretta è già installata."
      if (( pending )); then
        echo "ATTENZIONE: restano processi da sostituire; pianificare il ricambio dei servizi."
      fi
    fi
    echo "Questo esito riguarda i pacchetti controllati, non certifica tutti i siti."
  elif (( status == 0 )); then
    echo "AGGIORNAMENTO COMPLETATO; non occorre ripetere --apply."
    echo "Verificare il sito e una normale operazione applicativa."
  else
    echo "OPERAZIONE NON CONCLUSA: controllare i messaggi sopra."
    echo "Non ripetere --apply automaticamente; potrebbero esserci modifiche parziali."
  fi
  echo "============================================================"
}
trap final_summary EXIT

if (( EUID != 0 )); then
  echo "Eseguire con: sudo bash $0" >&2
  exit 1
fi
. /etc/os-release
if [[ ${ID:-} != ubuntu ]]; then
  echo "Questo script è previsto per Ubuntu." >&2
  exit 1
fi
case ${VERSION_ID:-} in
  22.04) branch=8.1; minimum='8.1.2-1ubuntu2.28' ;;
  24.04) branch=8.3; minimum='8.3.6-0ubuntu0.24.04.13' ;;
  *) echo "Release Ubuntu non supportata da questo script: ${VERSION_ID:-sconosciuta}" >&2; exit 1 ;;
esac
echo "Ubuntu $VERSION_ID: controllo PHP $branch (minimo $minimum)."
inventory=$(dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n')
mapfile -t packages < <(awk -v branch="$branch" '$2 == "installed" {name=$1; sub(/:.*/, "", name); prefix="php" branch; if (name == prefix || index(name, prefix "-") == 1 || name == "libapache2-mod-php" branch) print $1}' <<< "$inventory")
if (( ${#packages[@]} == 0 )); then
  echo "Nessun pacchetto PHP $branch installato." >&2
  exit 1
fi

fpm=0
modphp=0
if systemctl is-active --quiet "php$branch-fpm.service"; then
  fpm=1
  "/usr/sbin/php-fpm$branch" -t
fi
if systemctl is-active --quiet apache2.service; then
  apache2ctl configtest
  modules=$(apache2ctl -M)
  if grep -Eq 'php([0-9]+)?_module' <<< "$modules"; then modphp=1; fi
fi
echo "Servizi: PHP-FPM attivo=$fpm; Apache con mod_php attivo=$modphp"
others=$(awk -v branch="$branch" '$2 == "installed" && ($1 ~ /^php[0-9]+\.[0-9]+/ || $1 ~ /^libapache2-mod-php[0-9]+\.[0-9]+/) {name=$1; sub(/:.*/, "", name); prefix="php" branch; if (!(name == prefix || index(name, prefix "-") == 1 || name == "libapache2-mod-php" branch)) print $1}' <<< "$inventory")
if (( modphp )); then
  apply_blocked='Apache con mod_php: serve un riavvio completo pianificato di Apache.'
elif (( ! fpm )); then
  apply_blocked='Nessun PHP-FPM standard attivo; verificare PHP CLI/CGI o servizi personalizzati.'
fi
if [[ -n $others ]]; then
  apply_blocked="Altre versioni PHP installate da verificare: $others"
  unknown_version=1
fi
if [[ $mode == --apply ]]; then
  inventory=$(dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n')
  others=$(awk -v branch="$branch" '$2 == "installed" && ($1 ~ /^php[0-9]+\.[0-9]+/ || $1 ~ /^libapache2-mod-php[0-9]+\.[0-9]+/) {name=$1; sub(/:.*/, "", name); prefix="php" branch; if (!(name == prefix || index(name, prefix "-") == 1 || name == "libapache2-mod-php" branch)) print $1}' <<< "$inventory")
  if [[ -n $others ]]; then
    echo "Altre versioni PHP installate: verificare i siti prima di procedere: $others" >&2
    exit 1
  fi
  # Le estensioni distribuite separatamente (es. imagick) hanno versioni proprie.
  for package in "php$branch-common" "php$branch-cli" "php$branch-fpm" "php$branch-cgi" "libapache2-mod-php$branch"; do
    state=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
    [[ $state == installed ]] || continue
    installed=$(dpkg-query -W -f='${Version}' "$package")
    if [[ $installed != "$branch".*ubuntu* ]]; then
      echo "Pacchetto non riconosciuto come versione Ubuntu: $package $installed" >&2
      exit 1
    fi
  done
  audit=$(dpkg --audit)
  [[ -z $audit ]] || { echo "Stato pacchetti da riparare: $audit" >&2; exit 1; }
  if (( modphp || ! fpm )); then
    echo "Aggiornamento automatico bloccato: richiede PHP-FPM attivo senza mod_php."
    echo "Con mod_php pianificare aggiornamento e riavvio completo di Apache."
    echo "PHP CLI/CGI o servizi personalizzati richiedono una procedura separata."
    exit 1
  fi
  [[ -t 0 ]] || { echo "È richiesto un terminale interattivo." >&2; exit 1; }
  echo "APT può riavviare servizi durante l'installazione: possibili brevi interruzioni."
  echo "Procedere in una finestra concordata, con un backup ripristinabile."
  read -r -p 'Scrivere AGGIORNA per continuare: ' answer
  [[ $answer == AGGIORNA ]] || exit 1
  apt-get -o APT::Update::Error-Mode=any update
  for package in "php$branch-common" "php$branch-cli" "php$branch-fpm" "php$branch-cgi" "libapache2-mod-php$branch"; do
    state=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
    [[ $state == installed ]] || continue
    candidate=$(apt-cache policy "$package" | awk '$1 == "Candidate:" {print $2}')
    if [[ $candidate != "$branch".*ubuntu* ]]; then
      echo "Versione candidata non riconosciuta: $package $candidate" >&2
      exit 1
    fi
  done
fi
echo "Simulazione APT (in --check usa gli indici già presenti):"
# Mostra prima le modifiche; l'installazione successiva chiede conferma.
apt-get --simulate --no-remove install --only-upgrade "${packages[@]}"
if [[ $mode == --apply ]]; then
  candidate=$(apt-cache policy "php$branch-common" | awk '$1 == "Candidate:" {print $2}')
  if [[ $candidate != "$branch".*ubuntu* ]] || ! dpkg --compare-versions "$candidate" ge "$minimum"; then
    echo "Versione candidata non corretta o non riconosciuta: $candidate" >&2
    exit 1
  fi
  read -r -p 'Controllare il piano sopra. Scrivere APPLICA per installare: ' answer
  [[ $answer == APPLICA ]] || exit 1
  apt-get --no-remove install --only-upgrade "${packages[@]}"
fi

echo "Controllo dei componenti principali:"
for package in "php$branch-common" "php$branch-cli" "php$branch-fpm" "php$branch-cgi" "libapache2-mod-php$branch"; do
  if record=$(dpkg-query -W -f='${db:Status-Status} ${Version}' "$package" 2>/dev/null) && [[ $record == installed\ * ]]; then
    version=${record#installed }
    versions_checked=1
    printf '%s: %s\n' "$package" "$version"
    if [[ $version != "$branch".*ubuntu* ]]; then
      echo "Versione non riconosciuta: verifica manuale necessaria."
      unknown_version=1
    elif ! dpkg --compare-versions "$version" ge "$minimum"; then
      echo "Da aggiornare: versione precedente alla correzione PHP2SHELL."
      needs_update=1
    fi
  fi
done
if [[ $mode == --apply ]] && (( ! versions_checked || needs_update || unknown_version )); then
  echo "Verifica versioni non superata dopo l'installazione." >&2
  exit 1
fi

reloaded=0
if [[ $mode == --apply ]] && systemctl is-active --quiet "php$branch-fpm.service"; then
  "/usr/sbin/php-fpm$branch" -t
  systemctl reload "php$branch-fpm.service"
  systemctl is-active --quiet "php$branch-fpm.service"
  echo "PHP-FPM: ricaricamento richiesto, servizio attivo."
  reloaded=1
fi
if [[ $mode == --apply ]] && systemctl is-active --quiet apache2.service; then
  apache2ctl configtest
  modules=$(apache2ctl -M 2>/dev/null)
  if [[ $modules == *php_module* || $modules == *php8_module* ]]; then
    echo "mod_php rilevato: serve un riavvio completo pianificato di Apache." >&2
    exit 2
  fi
fi

echo "Controllo rapido dei processi con file PHP sostituiti:"
pending=0
for maps in /proc/[0-9]*/maps; do
  [[ -r $maps ]] || continue
  if grep -Eq '/[^ ]*(php|libphp)[^ ]*.*\(deleted\)' "$maps" 2>/dev/null; then
    pid=${maps#/proc/}
    pid=${pid%/maps}
    printf 'Da ricontrollare: PID %s (%s)\n' "$pid" "$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    pending=1
  fi
done
if (( pending )); then
  echo "ATTENZIONE: alcuni processi usano ancora file PHP sostituiti."
  echo "Le richieste in corso possono dover terminare. Ricontrollare usando --check."
fi
if [[ $mode == --apply ]] && (( ! reloaded )); then
  echo "ATTENZIONE: nessun servizio PHP $branch standard ricaricato; verificare come viene eseguito il sito."
fi
echo "Nessun riavvio del sistema eseguito dallo script."
echo "Il controllo non copre container, altre versioni PHP o installazioni personalizzate."
echo "Le versioni dei pacchetti non certificano quale runtime venga usato dal sito."
if [[ $mode == --check ]]; then
  echo "Modalità controllo: nessun aggiornamento o ricaricamento effettuato."
  if (( pending || needs_update || unknown_version || ! versions_checked )); then exit 2; fi
  exit 0
fi
echo "Verificare ora una pagina del sito e una normale operazione dell'applicazione."
if (( pending || ! reloaded )); then
  exit 2
fi
