# Lazarus5K

> **English summary.** Lazarus5K turns a 27" 5K iMac (late 2015, Intel, macOS Monterey) into a Retina external display, with audio, for a newer Apple Silicon Mac. The host creates a virtual display through the private `CGVirtualDisplay` API, captures it with ScreenCaptureKit and sends only the changed 128×128 tiles, compressed losslessly with LZ4, over a Thunderbolt Bridge link. The viewer draws them with Metal and plays the system audio. It is a personal hobby project and has been tested on a single hardware setup only. Documentation below is in Italian.

Usa un iMac 27" 5K come monitor esterno Retina, con l'audio, per un Mac Apple Silicon.
Il Mac principale invia lo schermo all'iMac via cavo Thunderbolt, senza perdita di qualità.

È **un'unica app, Lazarus5K.app**, da copiare su entrambi i Mac: sceglie da sola il ruolo in base al processore. Sull'iMac parte all'accesso e resta in attesa in background; quando il Mac principale si collega va a schermo intero da sola.

_Nome di sviluppo: RelayLite. Le due parti si chiamano Host e Viewer (anche come comandi da Terminale, RelayHost e RelayViewer), e in macOS il monitor virtuale compare come "iMac 5K (RelayLite)"._

## Come funziona

L'**Host** gira sul Mac principale (Apple Silicon):
- crea un monitor virtuale Retina ("sembra 2560×1440", 5120×2880 pixel reali) con l'API privata `CGVirtualDisplay`;
- lo cattura con ScreenCaptureKit e lo confronta con l'ultimo frame inviato, a tile da 128×128;
- invia solo i tile cambiati, compressi LZ4 senza perdita, così testo e interfaccia restano nitidi;
- cattura l'audio di sistema e lo invia su una seconda connessione TCP, così i frame pesanti non lo interrompono.

Il **Viewer** gira sull'iMac:
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
scripts/build-app.sh
```

Lo script compila per Apple Silicon e per Intel, unisce i due binari e crea `dist/Lazarus5K.app`, firmata localmente (firma "ad-hoc"). È la stessa app per entrambi i Mac.

Nota: `Package.swift` passa `-runtime-compatibility-version none` al compilatore, perché le toolchain Swift recenti non includono più per x86_64 le librerie di retro-compatibilità del runtime. Su macOS 12.3 e successivi non servono.

## Uso

1. **Collega i due Mac** con il cavo. Su entrambi, in Rete, compare **Ponte Thunderbolt** con un indirizzo 169.254.x.x assegnato automaticamente. Il Wi-Fi può restare acceso: le connessioni passano solo dal cavo.
2. **Copia `Lazarus5K.app` in Applicazioni su entrambi i Mac.** La prima volta aprila con clic destro › **Apri** › **Apri**, perché non è firmata da uno sviluppatore registrato. Se l'hai trasferita con AirDrop o da browser e macOS dice che è danneggiata, togli la quarantena:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Lazarus5K.app
   ```

3. **Sull'iMac** l'app non mostra finestre: compare solo un'icona a forma di monitor nella barra dei menu, con lo stato "In attesa del Mac principale…". Si imposta da sola per partire a ogni accesso: dal menu puoi togliere la spunta **Avvia all'accesso**.
4. **Sul Mac principale** l'app crea subito il monitor virtuale e cerca l'iMac. La prima volta macOS chiede il permesso **Registrazione schermo e audio di sistema**: abilita Lazarus5K, poi chiudi e riapri l'app.
5. L'iMac va a schermo intero da solo appena riceve lo schermo. In Impostazioni di Sistema › Monitor del Mac principale compare "iMac 5K (RelayLite)": posizionalo dove preferisci.

Dal menu dell'icona:
- sul Mac principale, **Disattiva monitor iMac** rimuove il monitor virtuale e l'iMac torna al suo desktop;
- sull'iMac, **Esc** nasconde lo schermo del Mac finché resta collegato, e **Mostra lo schermo del Mac** lo fa ricomparire.

Se Bonjour non trova l'iMac, puoi indicare il suo indirizzo una volta per tutte sul Mac principale, poi riaprire l'app:

```bash
defaults write io.github.mrstark2.lazarus5k imacAddress 169.254.x.y
```

### Da Terminale (alternativa)

Le due parti esistono anche come comandi separati, utili per vedere i messaggi di diagnostica:

```bash
swift build -c release --product RelayHost
swift build -c release --product RelayViewer --arch x86_64   # l'iMac è Intel
swift build -c release --show-bin-path                        # dove finiscono i binari
```

Sull'iMac `./RelayViewer` va subito a schermo intero (Esc per uscire). Sul Mac principale `./RelayHost` trova l'iMac via Bonjour, oppure `./RelayHost <indirizzo-IP-dell-iMac>`. In questo caso il permesso Registrazione schermo va dato al Terminale.

### Audio

L'audio viene catturato dal sistema, quindi esce anche dagli altoparlanti del Mac principale. Per sentirlo solo sull'iMac:
- prova ad azzerare il volume del Mac principale e verifica se l'iMac continua a suonare;
- se si zittisce anche l'iMac, installa [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) (gratuito, open source) e sceglilo come uscita audio del Mac principale: fa da uscita "muta" e la cattura continua a funzionare.

## Limiti noti

- Usa l'API **privata e non documentata** `CGVirtualDisplay`: un aggiornamento di macOS potrebbe romperla in qualsiasi momento.
- **Testato solo** su un iMac 27" 5K fine 2015 con macOS Monterey e su un Mac Apple Silicon. Altre configurazioni potrebbero non funzionare.
- Ottimo per lavoro, testo e browser. Video a schermo intero e giochi possono perdere fps, perché ogni frame cambia quasi tutto lo schermo.
- L'app ha solo una firma locale: al primo avvio serve clic destro › Apri. Ogni volta che la ricompili, macOS la considera un'app nuova e può chiedere di nuovo il permesso Registrazione schermo.
- L'iMac deve essere già acceso e con l'utente collegato: non si può accendere o risvegliare dal Mac principale.

## Risoluzione problemi

### "Monitor virtuale non trovato tra gli schermi catturabili"

L'Host riprova da solo per qualche secondo, poi si ferma con questo messaggio. Da Terminale, RelayHost stampa anche l'elenco degli schermi che ScreenCaptureKit vede. Prova, nell'ordine:

1. **Permesso Registrazione schermo**: in Impostazioni di Sistema › Privacy e sicurezza › Registrazione schermo e audio di sistema, verifica che Lazarus5K (o il Terminale, se usi RelayHost) sia abilitato. Se lo era già, toglilo e rimettilo, poi chiudi e riapri l'app. Dopo una ricompilazione serve di nuovo.
2. **Duplicazione**: se il monitor virtuale è impostato per duplicare un altro schermo, ScreenCaptureKit non lo vede. L'Host prova a disattivare la duplicazione da solo; se non ci riesce, in Impostazioni di Sistema › Monitor imposta "iMac 5K (RelayLite)" come monitor esteso, non duplicato.
3. **Riavvio**: dopo molti avvii e chiusure, macOS a volte conserva monitor virtuali "fantasma". Riavvia il Mac principale e riapri l'app.

### Schermo nero sull'iMac

Quasi sempre manca il permesso di Registrazione schermo sul Mac principale: vedi il punto 1 qui sopra.

### Il Mac principale non trova l'iMac

Controlla che sull'iMac l'icona di Lazarus5K sia nella barra dei menu (o che RelayViewer sia aperto) e che il Ponte Thunderbolt abbia un indirizzo 169.254.x.x su entrambi i Mac. In alternativa indica l'indirizzo IP dell'iMac: con l'app usa il comando `defaults write` della sezione Uso, da Terminale `./RelayHost <indirizzo-IP-dell-iMac>`.

Se sull'iMac compare un avviso del firewall che chiede di accettare le connessioni in entrata per Lazarus5K, consentile.

### Togliere l'avvio automatico dall'iMac

Dal menu dell'icona togli la spunta **Avvia all'accesso**. In alternativa cancella il file `~/Library/LaunchAgents/io.github.mrstark2.lazarus5k.viewer.plist`.

### Stop (standby) del Mac principale

Finché l'Host è attivo, il Mac principale non va in stop per inattività. Lo schermo può comunque spegnersi dopo il tempo impostato in Impostazioni di Sistema, ma il Mac non va in stop. Chiudere il coperchio di un portatile lo manda invece in stop, a meno che sia collegato all'alimentatore e a un monitor esterno.

Al risveglio l'Host riavvia da solo la cattura e ritrasmette tutto lo schermo. Se l'iMac non risponde più, la connessione cade in una decina di secondi e l'Host si ricollega. Non serve riaprire niente su nessuno dei due Mac. Se è il Mac principale a sparire, anche l'iMac se ne accorge in una decina di secondi e torna al suo desktop.

## Licenza

Distribuito con licenza MIT: vedi il file [LICENSE](LICENSE).
