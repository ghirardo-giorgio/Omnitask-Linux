import QtQuick
import QtQuick.Layouts
import Quickshell

// Lo schermo di un telefono, con i tasti per muoverlo.
//
// Non e' un mirroring, e non puo' esserlo: una cattura costa mezzo secondo sul
// telefono, e il video vero passa da un programma a parte (il pulsante
// «Mirroring» apre scrcpy). Quello che c'e' qui e' una successione di
// fotografie — due al secondo con «Segui» acceso, una dopo ogni gesto quando
// e' spento — sopra la quale si tocca, si trascina, si scorre e si scrive.
//
// Il gesto viene deciso al rilascio, come lo decide un telefono vero: fermo e
// breve e' un tocco, fermo e lungo e' una pressione lunga, in movimento e' un
// trascinamento fatto di down/move/up. Uno `swipe` solo non basterebbe: ad
// Android arriverebbe come un lancio, e trascinare un'icona sarebbe impossibile.
//
// La conversione dal pixel della finestra a quello del telefono non ha numeri
// scritti a mano: la risoluzione vera arriva da `sourceSize` dell'immagine, e
// il fattore di scala da `paintedWidth`, che tiene gia' conto del
// ridimensionamento della finestra. Un telefono ruotato cambia entrambe le
// cose da solo.
Item {
    id: root

    // Il nome del telefono, come lo chiama KDE Connect.
    property string device: ""

    // Quello che si sta digitando, in attesa di partire in blocco: una lettera
    // per comando sarebbe un viaggio di andata e ritorno per lettera.
    property string typed: ""

    // La tastiera vale solo se il fuoco e' qui e non nel campo del PIN.
    focus: true

    Keys.onPressed: event => root.handleKey(event)

    // Il campo del PIN resta nascosto finche' non lo si chiede: e' un posto
    // dove si scrive un segreto, e non deve stare aperto per abitudine.
    property bool askingPin: false

    // Il ri-accoppiamento in corso. E' un modo a parte e non un pulsante che
    // fa una cosa sola perche' e' una conversazione: si dice al telefono di
    // rimettersi in ascolto, lo si aspetta, e le sei cifre arrivano dopo.
    property bool repairing: false

    onDeviceChanged: root.reload()

    // Rilegge stato e schermo del telefono attuale.
    //
    // Separata da `onDeviceChanged` perche' riaprire la finestra sullo stesso
    // telefono e' la cosa piu' normale del mondo — un doppio clic sulla stessa
    // riga — e in quel caso `device` non cambia, il segnale non scatta, e si
    // resterebbe a guardare la fotografia di dieci minuti fa credendola di
    // adesso.
    function reload(): void {
        root.askingPin = false;
        pin.text = "";
        root.repairing = false;
        code.text = "";
        waiting.tries = 0;
        root.forceActiveFocus();

        if (root.device !== "")
            PhoneAdb.look(root.device);
    }

    // I tasti del PC sul telefono. Le lettere si accumulano e partono insieme;
    // i tasti che non scrivono niente vanno subito, perche' sono comandi.
    function handleKey(event: var): void {
        if (!PhoneAdb.ready)
            return;

        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;

        if (ctrl) {
            if (event.key === Qt.Key_H)
                PhoneAdb.key("HOME");
            else if (event.key === Qt.Key_J)
                PhoneAdb.key("APP_SWITCH");
            else
                return;

            event.accepted = true;
            return;
        }

        switch (event.key) {
        case Qt.Key_Escape:
            PhoneAdb.key("BACK");
            break;
        case Qt.Key_Backspace:
            PhoneAdb.key("DEL");
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            PhoneAdb.key("ENTER");
            break;
        case Qt.Key_Left:
            PhoneAdb.key("DPAD_LEFT");
            break;
        case Qt.Key_Right:
            PhoneAdb.key("DPAD_RIGHT");
            break;
        case Qt.Key_Up:
            PhoneAdb.key("DPAD_UP");
            break;
        case Qt.Key_Down:
            PhoneAdb.key("DPAD_DOWN");
            break;
        case Qt.Key_F5:
            PhoneAdb.capture();
            break;
        default:
            // Tutto quello che ha una lettera da scrivere; i tasti muti (Shift,
            // Alt, le funzioni) non hanno testo e non devono finire nel flusso.
            if (event.text === "" || event.text.charCodeAt(0) < 32)
                return;

            root.typed += event.text;
            typing.restart();
        }

        event.accepted = true;
    }

    Timer {
        id: typing

        interval: 120

        onTriggered: {
            const text = root.typed;
            root.typed = "";
            PhoneAdb.type(text);
        }
    }

    // Finche' il telefono non apre la finestra dell'accoppiamento non c'e'
    // niente da annunciare sulla rete, e l'unico modo di accorgersene e'
    // richiedere lo stato. Ogni giro costa due secondi e mezzo di ascolto
    // mDNS: si guarda ogni sei secondi e per due minuti, poi si smette — chi
    // non l'ha aperta in due minuti sta facendo altro, e il campo del codice
    // resta comunque utilizzabile.
    Timer {
        id: waiting

        property int tries: 0

        interval: 6000
        repeat: true
        running: root.repairing && PhoneAdb.repairStep === "code"
            && !PhoneAdb.pairingOpen && waiting.tries < 20

        onTriggered: {
            waiting.tries += 1;
            PhoneAdb.refresh();
        }
    }

    // Il campo del PIN si apre quando e' il telefono a chiederlo, non prima:
    // su un telefono senza blocco lo sblocco finisce con lo scorrimento e
    // nessuno deve digitare niente.
    Connections {
        target: PhoneAdb

        function onPinNeeded(): void {
            root.askingPin = true;
            pin.forceActiveFocus();
        }
    }

    // Un pulsante della barra: nome sopra, cosa fa quando non si puo' fare.
    component Key: Rectangle {
        id: key

        required property string label
        property bool enabled: true
        property color tint: "#c9d1d9"
        // Per i tasti che sono un glifo e basta: la fila e' larga quanto la
        // finestra, e una parola in piu' la farebbe traboccare.
        property string hint: ""

        signal activated

        implicitWidth: text.implicitWidth + 18
        implicitHeight: 26
        radius: 5
        color: key.enabled && hover.hovered ? "#21262d" : "#161b22"
        border.width: 1
        border.color: key.enabled && hover.hovered ? "#30363d" : "#21262d"
        opacity: key.enabled ? 1 : 0.4

        Text {
            id: text

            anchors.centerIn: parent
            color: key.enabled ? key.tint : "#484f58"
            font.pixelSize: 11
            text: key.label
        }

        HoverHandler {
            id: hover

            cursorShape: key.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        }

        Tooltip {
            hovered: hover.hovered
            text: key.hint
        }

        TapHandler {
            onSingleTapped: {
                if (key.enabled)
                    key.activated();
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 8

        // --- chi e' e come sta ---------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                color: "#c9d1d9"
                font.pixelSize: 13
                text: root.device
            }

            Rectangle {
                implicitWidth: 7
                implicitHeight: 7
                radius: 4
                color: PhoneAdb.ready ? "#3fb950" : (PhoneAdb.adbState === "unauthorized" ? "#d29922" : "#484f58")
            }

            Text {
                color: "#6e7681"
                font.pixelSize: 10
                text: {
                    if (PhoneAdb.busy)
                        return I18n.t("in corso…");
                    if (PhoneAdb.ready)
                        return PhoneAdb.address;
                    if (PhoneAdb.adbState === "unauthorized")
                        return I18n.t("da autorizzare sul telefono");
                    return I18n.t("ADB non collegato");
                }
            }
        }

        // --- lo schermo ------------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: 6
            color: "#161b22"
            border.width: 1
            border.color: "#21262d"
            clip: true

            Image {
                id: screen

                anchors.fill: parent
                anchors.margins: 4
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                // Ogni scatto ha un nome nuovo, quindi la cache non mente mai;
                // resta spenta perche' i PNG sono grandi e non servono due volte.
                cache: false
                smooth: true
                source: PhoneAdb.shot !== "" ? "file://" + PhoneAdb.shot : ""

                // Dove finisce davvero il disegno dentro l'area: con
                // PreserveAspectFit restano due margini, e ignorarli sposta
                // ogni tocco verso il basso o di lato.
                readonly property real offsetX: (width - paintedWidth) / 2
                readonly property real offsetY: (height - paintedHeight) / 2
                readonly property real factor: paintedWidth > 0 ? sourceSize.width / paintedWidth : 0

                MouseArea {
                    id: touch

                    anchors.fill: parent
                    enabled: screen.status === Image.Ready && PhoneAdb.ready && screen.factor > 0
                    acceptedButtons: Qt.LeftButton
                    cursorShape: PhoneAdb.ready ? Qt.PointingHandCursor : Qt.ArrowCursor

                    // Il gesto in corso, in pixel del telefono.
                    property point from: Qt.point(0, 0)
                    property real began: 0
                    property bool holding: false
                    property bool dragging: false
                    // Quando e' partito l'ultimo `move`: a raffica libera
                    // sarebbero decine di comandi per un gesto, e ognuno costa
                    // un viaggio fino al telefono.
                    property real moved: 0

                    // Dove sta il dito nella finestra, per disegnarlo: a due
                    // fotografie al secondo l'immagine non segue la mano, e
                    // senza un segno il gesto sembra non essere arrivato.
                    property point mark: Qt.point(0, 0)
                    property point markTo: Qt.point(0, 0)

                    function toPhone(x: real, y: real): point {
                        return Qt.point((x - screen.offsetX) * screen.factor,
                                        (y - screen.offsetY) * screen.factor);
                    }

                    // Fuori dall'immagine c'e' la cornice, non il telefono: un
                    // tocco li' andrebbe a finire su una coordinata negativa,
                    // che Android accetta senza dire niente.
                    function inside(p: point): bool {
                        return p.x >= 0 && p.y >= 0
                            && p.x <= screen.sourceSize.width
                            && p.y <= screen.sourceSize.height;
                    }

                    onPressed: mouse => {
                        root.forceActiveFocus();

                        const p = touch.toPhone(mouse.x, mouse.y);

                        if (!touch.inside(p))
                            return;

                        touch.from = p;
                        touch.began = Date.now();
                        touch.moved = 0;
                        touch.holding = true;
                        touch.dragging = false;
                        touch.mark = Qt.point(mouse.x, mouse.y);
                        touch.markTo = touch.mark;
                    }

                    onPositionChanged: mouse => {
                        if (!touch.holding)
                            return;

                        const p = touch.toPhone(mouse.x, mouse.y);
                        touch.markTo = Qt.point(mouse.x, mouse.y);

                        // Sotto una dozzina di pixel e' la mano che trema
                        // mentre preme, non l'inizio di un trascinamento.
                        if (!touch.dragging
                            && Math.hypot(p.x - touch.from.x, p.y - touch.from.y) > 12) {
                            touch.dragging = true;
                            PhoneAdb.drag("down", touch.from.x, touch.from.y);
                        }

                        if (touch.dragging && Date.now() - touch.moved > 45) {
                            touch.moved = Date.now();
                            PhoneAdb.drag("move", p.x, p.y);
                        }
                    }

                    onReleased: mouse => {
                        if (!touch.holding)
                            return;

                        touch.holding = false;

                        const p = touch.toPhone(mouse.x, mouse.y);
                        const held = Date.now() - touch.began;

                        if (touch.dragging) {
                            touch.dragging = false;
                            PhoneAdb.drag("up", p.x, p.y);
                            return;
                        }

                        if (!touch.inside(p))
                            return;

                        if (held > 500)
                            PhoneAdb.longPress(p.x, p.y, held);
                        else
                            PhoneAdb.tap(p.x, p.y);
                    }

                    onCanceled: {
                        if (touch.dragging)
                            PhoneAdb.drag("up", touch.from.x, touch.from.y);

                        touch.holding = false;
                        touch.dragging = false;
                    }
                }

                WheelHandler {
                    enabled: screen.status === Image.Ready && PhoneAdb.ready && screen.factor > 0

                    onWheel: event => {
                        const p = touch.toPhone(event.x, event.y);

                        if (!touch.inside(p))
                            return;

                        // Un quarto di schermo per scatto della rotella, nel
                        // verso in cui andrebbe il dito: la rotella in su fa
                        // scendere il contenuto, cioe' il dito scorre in giu'.
                        const step = Math.round(screen.sourceSize.height * 0.25);
                        PhoneAdb.scroll(p.x, p.y, event.angleDelta.y > 0 ? step : -step);
                    }
                }

                // Il dito, mentre e' appoggiato: il punto di partenza e dove
                // sta adesso. Sparisce appena si rilascia.
                Rectangle {
                    visible: touch.holding
                    x: touch.mark.x - 7
                    y: touch.mark.y - 7
                    width: 14
                    height: 14
                    radius: 7
                    color: "transparent"
                    border.width: 2
                    border.color: "#58a6ff"
                    opacity: 0.8
                }

                Rectangle {
                    visible: touch.dragging
                    x: touch.markTo.x - 5
                    y: touch.markTo.y - 5
                    width: 10
                    height: 10
                    radius: 5
                    color: "#58a6ff"
                    opacity: 0.7
                }
            }

            // Il ri-accoppiamento copre lo schermo invece di scriversi sotto
            // ai pulsanti: e' una cosa da fare sul telefono, e mentre la si fa
            // la fotografia di prima non serve a niente. Non riusa il
            // segnaposto qui sotto perche' quello sparisce appena c'e'
            // un'immagine, e la riassociazione si puo' chiedere anche a
            // telefono ancora visibile.
            Rectangle {
                anchors.fill: parent
                anchors.margins: 4
                visible: root.repairing
                radius: 4
                color: "#0d1117"
                opacity: 0.97

                Column {
                    anchors.centerIn: parent
                    width: parent.width - 40
                    spacing: 8

                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        color: "#d29922"
                        font.pixelSize: 12
                        text: I18n.t("Riassociazione")
                    }

                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        color: "#c9d1d9"
                        font.pixelSize: 11
                        lineHeight: 1.3
                        text: {
                            if (PhoneAdb.busy && PhoneAdb.repairStep === "")
                                return I18n.t("sto guardando cosa manca…");

                            if (PhoneAdb.repairStep === "authorize")
                                return I18n.t("Il telefono ha revocato la chiave di questo PC. Sullo schermo del telefono e' appena ricomparsa la richiesta «Consentire il debug USB?»: confermala, e spunta «Consenti sempre da questo computer».");

                            if (PhoneAdb.repairStep !== "code")
                                return PhoneAdb.lastError !== "" ? PhoneAdb.lastError : I18n.t("niente da riassociare");

                            if (PhoneAdb.pairingOpen)
                                return I18n.t("Il telefono sta chiedendo il codice: digita qui sotto le sei cifre che mostra.");

                            return I18n.t("Sul telefono: Opzioni sviluppatore → Debug wireless → «Accoppia dispositivo con codice di accoppiamento». Poi digita qui sotto le sei cifre che compaiono.");
                        }
                    }

                    // Il codice vale finche' quella finestra resta aperta, e
                    // dirlo prima evita di farlo scoprire con un rifiuto.
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        visible: PhoneAdb.repairStep === "code"
                        color: "#6e7681"
                        font.pixelSize: 10
                        text: PhoneAdb.pairingOpen
                            ? I18n.t("il codice cambia a ogni apertura di quella finestra")
                            : I18n.t("in attesa che il telefono lo chieda…")
                    }
                }
            }

            // Al posto dell'immagine, quando non c'e': cosa manca e come si
            // rimedia, non un rettangolo vuoto da interpretare.
            Text {
                anchors.centerIn: parent
                anchors.margins: 20
                width: parent.width - 40
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                // Durante la riassociazione parla il riquadro qui sopra: due
                // testi sovrapposti sarebbero due istruzioni diverse nello
                // stesso punto.
                visible: PhoneAdb.shot === "" && !root.repairing
                color: "#6e7681"
                font.pixelSize: 11
                text: {
                    if (PhoneAdb.busy)
                        return I18n.t("scatto in corso…");
                    if (PhoneAdb.hint !== "")
                        return PhoneAdb.hint;
                    if (!PhoneAdb.ready)
                        return I18n.t("questo telefono non risponde ad ADB");
                    if (PhoneAdb.awake === false)
                        return I18n.t("schermo spento");
                    return I18n.t("premi Aggiorna per vedere lo schermo");
                }
            }
        }

        // --- il PIN, solo quando lo si e' chiesto ----------------------------
        RowLayout {
            Layout.fillWidth: true
            visible: root.askingPin
            spacing: 6

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 5
                color: "#0d1117"
                border.width: 1
                border.color: pin.activeFocus ? "#58a6ff" : "#30363d"

                TextInput {
                    id: pin

                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#c9d1d9"
                    font.pixelSize: 12
                    echoMode: TextInput.Password
                    inputMethodHints: Qt.ImhDigitsOnly
                    onAccepted: root.sendPin()

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: pin.text === ""
                        color: "#484f58"
                        font.pixelSize: 11
                        text: I18n.t("PIN, poi Invio")
                    }
                }
            }

            Key {
                label: I18n.t("Invia")
                tint: "#58a6ff"
                onActivated: root.sendPin()
            }
        }

        // --- il codice di accoppiamento, solo durante la riassociazione ------
        //
        // Gemella della riga del PIN, con una differenza: il codice non si
        // nasconde mentre lo si scrive. E' gia' scritto in grande sullo schermo
        // del telefono, non e' un segreto, e mascherarlo toglierebbe solo la
        // possibilita' di rileggere quel che si e' digitato.
        RowLayout {
            Layout.fillWidth: true
            visible: root.repairing
            spacing: 6

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 26
                visible: PhoneAdb.repairStep === "code"
                radius: 5
                color: "#0d1117"
                border.width: 1
                border.color: code.activeFocus ? "#58a6ff" : "#30363d"

                // Il fuoco ci arriva da se' quando il campo compare: chi ha in
                // mano il telefono e sta leggendo sei cifre non deve anche
                // ricordarsi di cliccare qui prima di scriverle.
                onVisibleChanged: {
                    if (visible)
                        code.forceActiveFocus();
                }

                TextInput {
                    id: code

                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#c9d1d9"
                    font.pixelSize: 12
                    maximumLength: 6
                    inputMethodHints: Qt.ImhDigitsOnly
                    validator: RegularExpressionValidator {
                        regularExpression: /[0-9]*/
                    }
                    onAccepted: root.sendCode()

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: code.text === ""
                        color: "#484f58"
                        font.pixelSize: 11
                        text: I18n.t("sei cifre, poi Invio")
                    }
                }
            }

            Key {
                visible: PhoneAdb.repairStep === "code"
                label: I18n.t("Invia")
                enabled: code.text.length === 6 && !PhoneAdb.busy
                tint: "#58a6ff"
                onActivated: root.sendCode()
            }

            // Confermata la chiave sul telefono non torna nessun segnale: e'
            // una finestra di Android, e l'unico modo di sapere com'e' andata
            // e' richiedere lo stato.
            Key {
                visible: PhoneAdb.repairStep === "authorize"
                label: I18n.t("Ho confermato")
                enabled: !PhoneAdb.busy
                tint: "#58a6ff"
                onActivated: {
                    root.stopRepair();
                    PhoneAdb.connect();
                }
            }

            Item {
                Layout.fillWidth: PhoneAdb.repairStep !== "code"
            }

            Key {
                label: I18n.t("Annulla")
                onActivated: root.stopRepair()
            }
        }

        // --- i tasti ---------------------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Key {
                label: PhoneAdb.following ? I18n.t("Fermo") : I18n.t("Segui")
                enabled: PhoneAdb.ready && PhoneAdb.sessionUp
                tint: PhoneAdb.following ? "#3fb950" : "#c9d1d9"
                onActivated: PhoneAdb.follow(!PhoneAdb.following)
            }

            Key {
                label: I18n.t("Aggiorna")
                enabled: PhoneAdb.ready && !PhoneAdb.busy
                tint: "#58a6ff"
                onActivated: PhoneAdb.capture()
            }

            // I gesti a due dita e i sessanta fotogrammi al secondo stanno di
            // la', in un programma fatto per quello.
            //
            // Il pulsante resta premibile anche senza scrcpy installato, e
            // sbiadito per dire che manca qualcosa: chi lo preme si sente
            // rispondere con il comando per installarlo, che e' piu' di quanto
            // dica un pulsante spento e molto piu' di uno che non c'e'.
            Key {
                label: I18n.t("Mirroring")
                enabled: PhoneAdb.ready
                tint: PhoneAdb.mirrorAvailable ? "#c9d1d9" : "#8b949e"
                onActivated: PhoneAdb.mirror()
            }

            Key {
                label: PhoneAdb.awake === false ? I18n.t("Accendi") : I18n.t("Spegni")
                enabled: PhoneAdb.ready && !PhoneAdb.busy
                onActivated: PhoneAdb.display(PhoneAdb.awake === false ? "on" : "off")
            }

            Key {
                label: root.askingPin ? I18n.t("Annulla") : I18n.t("Sblocca")
                enabled: PhoneAdb.ready && !PhoneAdb.busy
                onActivated: {
                    if (root.askingPin) {
                        root.askingPin = false;
                        pin.text = "";
                        return;
                    }

                    // Si tenta senza segreti: sveglia e scorrimento. Se il
                    // keyguard resiste, `pinNeeded` apre il campo da solo.
                    PhoneAdb.unlock("");
                }
            }

            // Compare solo quando serve: debug acceso e sessione caduta, che
            // e' il modo in cui una connessione wireless finisce da sola.
            Key {
                visible: !PhoneAdb.ready && PhoneAdb.hint !== ""
                label: I18n.t("Collega")
                enabled: !PhoneAdb.busy
                tint: "#58a6ff"
                onActivated: PhoneAdb.connect()
            }

            // Quando `Collega` non basta perche' e' il telefono ad aver tolto
            // l'autorizzazione. Un glifo e non una parola: la fila e' larga
            // quanto la finestra e «Riassocia» per esteso la farebbe
            // traboccare; cosa faccia lo dice l'etichetta al passaggio.
            Key {
                visible: !PhoneAdb.ready && !root.repairing
                label: "⚯"
                hint: I18n.t("Riassocia: il telefono ha tolto l'autorizzazione")
                enabled: !PhoneAdb.busy
                tint: "#d29922"
                onActivated: root.startRepair()
            }

            Item {
                Layout.fillWidth: true
            }

            Key {
                label: "◁"
                enabled: PhoneAdb.ready && !PhoneAdb.busy
                onActivated: PhoneAdb.key("BACK")
            }

            Key {
                label: "◯"
                enabled: PhoneAdb.ready && !PhoneAdb.busy
                onActivated: PhoneAdb.key("HOME")
            }

            Key {
                label: "▢"
                enabled: PhoneAdb.ready && !PhoneAdb.busy
                onActivated: PhoneAdb.key("APP_SWITCH")
            }
        }

        // --- l'ultima parola -------------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                Layout.fillWidth: true
                visible: text !== ""
                elide: Text.ElideRight
                font.pixelSize: 10
                color: PhoneAdb.lastError !== "" ? "#d29922" : "#6e7681"
                text: PhoneAdb.lastError !== "" ? PhoneAdb.lastError : PhoneAdb.note
            }

            // Quanto e' vecchio quello che si sta guardando. Non e' un vezzo:
            // su un'immagine ferma e' l'unica cosa che distingue uno schermo
            // che non cambia da un collegamento che non risponde piu'.
            Text {
                visible: PhoneAdb.sessionUp
                font.pixelSize: 10
                color: PhoneAdb.following ? "#3fb950" : "#6e7681"
                text: {
                    if (!PhoneAdb.following)
                        return I18n.t("in pausa");

                    if (PhoneAdb.frameMs <= 0)
                        return I18n.t("in ascolto…");

                    return (1000 / PhoneAdb.frameMs).toFixed(1) + " fps";
                }
            }
        }
    }

    // Il ri-accoppiamento comincia chiedendo allo script quale delle due
    // autorizzazioni manchi: la chiave RSA o l'accoppiamento wireless. Le
    // istruzioni che compaiono dopo sono quelle del caso vero, non un elenco
    // dei due in cui l'utente deve riconoscere il proprio.
    function startRepair(): void {
        root.askingPin = false;
        pin.text = "";
        root.repairing = true;
        code.text = "";
        waiting.tries = 0;
        PhoneAdb.repair();
    }

    function stopRepair(): void {
        root.repairing = false;
        code.text = "";
        PhoneAdb.repairStep = "";
        root.forceActiveFocus();
    }

    function sendCode(): void {
        // Sei cifre esatte: lo script rifiuterebbe comunque, ma farglielo dire
        // dopo un viaggio di andata e ritorno sarebbe farlo dire piu' tardi e
        // basta.
        if (code.text.length !== 6)
            return;

        PhoneAdb.pairWith(code.text);
        code.text = "";
    }

    function sendPin(): void {
        if (pin.text === "")
            return;

        PhoneAdb.unlock(pin.text);
        // Sparisce dal campo appena parte: un PIN che resta scritto sullo
        // schermo e' un PIN che qualcuno legge alle spalle.
        pin.text = "";
        root.askingPin = false;
    }
}
