# Lazarus5K

> **English summary.** Lazarus5K turns a 27" 5K iMac (late 2015, Intel, macOS Monterey) into a Retina external display, with audio, for a newer Apple Silicon Mac. The host creates a virtual display through the private `CGVirtualDisplay` API, captures it with ScreenCaptureKit and sends only the changed 128×128 tiles, compressed losslessly with LZ4, over a Thunderbolt Bridge link. The viewer draws them with Metal and plays the system audio. It is a personal hobby project and has been tested on a single hardware setup only. Documentation below is in Italian.

Usa un iMac 27" 5K come monitor esterno Retina, con l'audio, per un Mac Apple Silicon.
Il Mac principale invia lo schermo all'iMac via cavo Thunderbolt, senza perdita di qualità.

_Nome di sviluppo: RelayLite. I due programmi si chiamano RelayHost e RelayViewer, e in macOS il monitor virtuale compare come "iMac 5K (RelayLite)"._

## Come funziona

**RelayHost** gira sul Mac principale (Apple Silicon):
- crea un monitor virtuale Retina ("sembra 2560×1440", 5120×2880 pixel reali) con l'API privata `CGVirtualDisplay`;
- lo cattura con ScreenCaptureKit e lo confronta con l'ultimo frame inviato, a tile da 128×128;
- invia solo i tile cambiati, compressi LZ4 senza perdita, così testo e interfaccia restano nitidi;
- cattura l'audio di sistema e lo invia su una seconda connessione TCP, così i frame pesanti non lo interrompono.

**RelayViewer** gira sull'iMac:
- decomprime i tile su tutti i core e li copia in una texture Metal;
- mostra la texture a schermo intero, pixel per pixel;
- riproduce l'audio con AVAudioEngine.

Non usa H.264/HEVC perché la decodifica hardware della GPU Skylake dell'iMac difficilmente regge un flusso 5K, e la compressione video rovina la leggibilità del testo.

## Requisiti

- **iMac 27" 5K** con **macOS Monterey 12.3 o successivo**, impostato su "Predefinito per il monitor" (2560×1440 Retina) in Preferenze di Sistema › Monitor.
- **Mac principale Apple Silicon** con **macOS 13 o successivo** (l'audio di sistema richiede macOS 13).
- **Cavo Thunderbolt**, fortemente consigliato: adattatore Apple Thunderbolt 3 (USB-C) → Thunderbolt 2 più un cavo Thunderbolt 2. Il 5K senza perdita ha bisogno di molta banda: in Ethernet gigabit funziona, ma rallenta molto quando cambia mezzo schermo.
- Sul Mac principale, Xcode oppure i Command Line Tools (`xcode-select --install`).

## Compilazione

Sul Mac principale, dalla cartella del progetto:

```bash
swift build -c release --product RelayHost
swift build -c release --product RelayViewer --arch x86_64   # l'iMac è Intel
```

I binari finiscono nella cartella indicata da:

```bash
swift build -c release --show-bin-path
```

Copia `RelayViewer` sull'iMac. Se lo trasferisci con AirDrop o da browser, togli la quarantena:

```bash
xattr -d com.apple.quarantine ./RelayViewer
```

Nota: `Package.swift` passa `-runtime-compatibility-version none` al Viewer, perché le toolchain Swift recenti non includono più per x86_64 le librerie di retro-compatibilità del runtime. Su macOS 12.3 e successivi non servono.

## Uso

1. Collega i due Mac con il cavo. Su entrambi, in Rete, compare **Ponte Thunderbolt** con un indirizzo 169.254.x.x assegnato automaticamente. Il Wi-Fi può restare acceso: le connessioni passano solo dal cavo.
2. Sull'iMac, da Terminale: `./RelayViewer` (Esc per uscire).
3. Sul Mac principale: `./RelayHost`, che trova l'iMac via Bonjour, oppure `./RelayHost <indirizzo-IP-dell-iMac>`.
4. Al primo avvio concedi al Terminale il permesso **Registrazione schermo e audio di sistema**, poi rilancia. Su macOS recenti potrebbe essere richiesto anche l'accesso alla **Rete locale**.
5. In Impostazioni di Sistema › Monitor compare "iMac 5K (RelayLite)": posizionalo dove preferisci.

### Audio

L'audio viene catturato dal sistema, quindi esce anche dagli altoparlanti del Mac principale. Per sentirlo solo sull'iMac:
- prova ad azzerare il volume del Mac principale e verifica se l'iMac continua a suonare;
- se si zittisce anche l'iMac, installa [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) (gratuito, open source) e sceglilo come uscita audio del Mac principale: fa da uscita "muta" e la cattura continua a funzionare.

## Limiti noti

- Usa l'API **privata e non documentata** `CGVirtualDisplay`: un aggiornamento di macOS potrebbe romperla in qualsiasi momento.
- **Testato solo** su un iMac 27" 5K fine 2015 con macOS Monterey e su un Mac Apple Silicon. Altre configurazioni potrebbero non funzionare.
- Ottimo per lavoro, testo e browser. Video a schermo intero e giochi possono perdere fps, perché ogni frame cambia quasi tutto lo schermo.
- È un prototipo da usare da Terminale: niente app, niente avvio automatico.

## Risoluzione problemi

### "Monitor virtuale non trovato tra gli schermi catturabili"

RelayHost riprova da solo per qualche secondo. Se poi esce con questo messaggio, stampa anche l'elenco degli schermi che ScreenCaptureKit vede. Prova, nell'ordine:

1. **Permesso Registrazione schermo**: in Impostazioni di Sistema › Privacy e sicurezza › Registrazione schermo e audio di sistema, verifica che il Terminale (o l'app da cui lanci RelayHost) sia abilitato. Se lo era già, toglilo e rimettilo, poi chiudi e riapri il Terminale.
2. **Duplicazione**: se il monitor virtuale è impostato per duplicare un altro schermo, ScreenCaptureKit non lo vede. RelayHost prova a disattivare la duplicazione da solo; se non ci riesce, in Impostazioni di Sistema › Monitor imposta "iMac 5K (RelayLite)" come monitor esteso, non duplicato.
3. **Riavvio**: dopo molti avvii e chiusure, macOS a volte conserva monitor virtuali "fantasma". Riavvia il Mac principale e rilancia RelayHost.

### Schermo nero sull'iMac

Quasi sempre manca il permesso di Registrazione schermo sul Mac principale: vedi il punto 1 qui sopra.

### RelayHost non trova l'iMac

Controlla che RelayViewer sia già in esecuzione e che il Ponte Thunderbolt abbia un indirizzo 169.254.x.x su entrambi i Mac. In alternativa passa direttamente l'indirizzo IP dell'iMac: `./RelayHost <indirizzo-IP-dell-iMac>`.

### Stop (standby) del Mac principale

Finché RelayHost è aperto, il Mac principale non va in stop per inattività. Lo schermo può comunque spegnersi dopo il tempo impostato in Impostazioni di Sistema, ma il Mac non va in stop. Chiudere il coperchio di un portatile lo manda invece in stop, a meno che sia collegato all'alimentatore e a un monitor esterno.

Al risveglio RelayHost riavvia da solo la cattura e ritrasmette tutto lo schermo. Se l'iMac non risponde più, la connessione cade in una decina di secondi e RelayHost si ricollega. Non serve rilanciare né RelayHost né RelayViewer.

## Licenza

Distribuito con licenza MIT: vedi il file [LICENSE](LICENSE).
