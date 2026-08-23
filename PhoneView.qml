import QtQuick
import QtQuick.Layouts
import Quickshell

// Lo schermo di un telefono, con i tasti per muoverlo.
//
// Non e' un mirroring: e' una fotografia, richiesta quando serve. Dopo ogni
// azione ne parte una nuova, cosi' quello che si vede e' sempre l'esito
// dell'ultimo clic — che e' l'unica cosa che rende utile un'immagine ferma.
//
// Il clic sull'immagine tocca il telefono nel punto corrispondente. La
// conversione non ha numeri scritti a mano: la risoluzione vera arriva da
// `sourceSize` dello screenshot, e il fattore di scala da `paintedWidth`, che
// tiene gia' conto del ridimensionamento della finestra. Un telefono ruotato
// cambia entrambe le cose da solo.
Item {
    id: root

    // Il nome del telefono, come lo chiama KDE Connect.
    property string device: ""

    // Il campo del PIN resta nascosto finche' non lo si chiede: e' un posto
    // dove si scrive un segreto, e non deve stare aperto per abitudine.
    property bool askingPin: false

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

        if (root.device !== "")
            PhoneAdb.look(root.device);
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

                TapHandler {
                    enabled: screen.status === Image.Ready && PhoneAdb.ready && screen.factor > 0

                    onSingleTapped: point => {
                        const x = (point.position.x - screen.offsetX) * screen.factor;
                        const y = (point.position.y - screen.offsetY) * screen.factor;

                        // Fuori dall'immagine c'e' la cornice, non il telefono:
                        // un tocco li' andrebbe a finire su una coordinata
                        // negativa, che Android accetta senza dire niente.
                        if (x < 0 || y < 0 || x > screen.sourceSize.width || y > screen.sourceSize.height)
                            return;

                        PhoneAdb.tap(x, y);
                    }
                }

                HoverHandler {
                    cursorShape: PhoneAdb.ready ? Qt.PointingHandCursor : Qt.ArrowCursor
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
                visible: PhoneAdb.shot === ""
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

        // --- i tasti ---------------------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Key {
                label: I18n.t("Aggiorna")
                enabled: PhoneAdb.ready && !PhoneAdb.busy
                tint: "#58a6ff"
                onActivated: PhoneAdb.capture()
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
        Text {
            Layout.fillWidth: true
            visible: text !== ""
            elide: Text.ElideRight
            font.pixelSize: 10
            color: PhoneAdb.lastError !== "" ? "#d29922" : "#6e7681"
            text: PhoneAdb.lastError !== "" ? PhoneAdb.lastError : PhoneAdb.note
        }
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
