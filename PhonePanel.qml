import QtQuick
import QtQuick.Layouts
import Quickshell

// Batteria, connessione e clipboard dei dispositivi accoppiati con KDE Connect.
//
// Si annuncia a KdeConnect alla nascita e si toglie quando muore: e' quello
// che fa partire la lettura nel momento in cui il pannello viene acceso dalle
// Opzioni, e che la ferma quando viene spento. L'elenco dei dispositivi non e'
// scritto da nessuna parte — si richiede ogni volta al demone — quindi un
// telefono accoppiato dopo compare da solo.
//
// La riga e' disegnata qui invece di riusare StatBar: fra il nome e la barra
// ci stanno le due frecce, e StatBar mette in fila etichetta, barra e valore
// senza posto in mezzo. Allargarlo per un solo pannello avrebbe complicato
// tutti gli altri che lo usano.
ColumnLayout {
    id: root

    spacing: 6

    Component.onCompleted: KdeConnect.watch()
    Component.onDestruction: KdeConnect.unwatch()

    // I motivi arrivano dal collector come codici, non come frasi: le parole
    // le sceglie chi mostra il dato, cosi' la stessa risposta serve il
    // pannello nella lingua scelta e il server MCP in inglese.
    function reasonText(code: string): string {
        switch (code) {
        case "unreachable":
            return I18n.t("non raggiungibile");
        case "not_reported":
            return I18n.t("il telefono non riporta la batteria");
        case "gsconnect_cannot_report":
            return I18n.t("GSConnect non pubblica la batteria");
        }
        return "";
    }

    RowLayout {
        Layout.fillWidth: true

        // Doppio clic sull'intestazione per rileggere subito, senza aspettare
        // il giro dei 30 secondi: serve quando hai appena accoppiato un
        // telefono o infilato il cavo.
        //
        // Sta qui e non sul pannello intero perche' sulla riga di un telefono
        // il doppio clic ne apre la finestra: annidati, i due gesti sono lo
        // stesso gesto, e scatterebbero tutti e due.
        TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: KdeConnect.refresh(true)
        }

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: "#c9d1d9"
            font.pixelSize: 12
            // Fra parentesi chi sta rispondendo: con due demoni installati
            // sapere da quale arriva il dato spiega perche' una freccia c'e'
            // e l'altra no.
            text: KdeConnect.sourceLabel.length > 0 ? I18n.t("Telefoni") + ` (${KdeConnect.sourceLabel})` : I18n.t("Telefoni")
        }

        Text {
            color: "#6e7681"
            font.pixelSize: 10
            text: {
                if (KdeConnect.loading && !KdeConnect.loaded)
                    return I18n.t("lettura…");
                const total = KdeConnect.paired.length;
                if (total === 0)
                    return "";
                return `${KdeConnect.online.length}/${total} ` + I18n.t("collegati");
            }
        }
    }

    Repeater {
        model: KdeConnect.paired

        ColumnLayout {
            id: device

            required property var modelData

            readonly property var battery: device.modelData.battery ?? null
            readonly property var status: KdeConnect.actionStatus[device.modelData.id] ?? null

            Layout.fillWidth: true
            spacing: 1

            // Doppio clic sul telefono: la finestra con lo schermo e i tasti.
            // Non un clic singolo — sulla riga ci sono gia' le frecce della
            // clipboard, e aprire una finestra per sbaglio da' fastidio.
            TapHandler {
                acceptedButtons: Qt.LeftButton
                onDoubleTapped: DashActions.openPhone(device.modelData.name)
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    Layout.preferredWidth: 92
                    elide: Text.ElideRight
                    color: "#8b949e"
                    font.pixelSize: 11
                    text: device.modelData.name
                }

                // --- clipboard: su verso il telefono, giu' verso il PC.
                // Non nascoste quando non si puo': una freccia che sparisce
                // lascia chiedersi se ci sia mai stata. Restano spente, e al
                // clic dicono perche'.
                Repeater {
                    model: [
                        {
                            glyph: "↑",
                            direction: "send",
                            hint: I18n.t("Invia appunti"),
                            can: device.modelData.can_send ?? false,
                            why: I18n.t("questo dispositivo non accetta la clipboard")
                        },
                        {
                            glyph: "↓",
                            direction: "receive",
                            hint: I18n.t("Ricevi appunti"),
                            can: device.modelData.can_receive ?? false,
                            why: I18n.t("ricevere richiede GSConnect accoppiato con questo dispositivo")
                        }
                    ]

                    Rectangle {
                        id: arrow

                        required property var modelData

                        implicitWidth: 18
                        implicitHeight: 18
                        radius: 4
                        color: arrow.modelData.can && arrowHover.hovered ? "#21262d" : "transparent"
                        border.width: 1
                        border.color: arrow.modelData.can && arrowHover.hovered ? "#30363d" : "transparent"

                        Text {
                            anchors.centerIn: parent
                            color: !arrow.modelData.can ? "#30363d" : (arrowHover.hovered ? "#58a6ff" : "#6e7681")
                            font.pixelSize: 11
                            text: arrow.modelData.glyph
                        }

                        HoverHandler {
                            id: arrowHover

                            cursorShape: arrow.modelData.can ? Qt.PointingHandCursor : Qt.ArrowCursor
                        }

                        // Su una freccia spenta l'etichetta dice il motivo
                        // invece del nome dell'azione: sapere come si
                        // chiamerebbe una cosa che non si puo' fare serve meno
                        // che sapere perche' non si puo' fare.
                        Tooltip {
                            hovered: arrowHover.hovered
                            text: arrow.modelData.can ? arrow.modelData.hint : arrow.modelData.why
                        }

                        TapHandler {
                            onSingleTapped: {
                                if (arrow.modelData.can)
                                    KdeConnect.clipboard(device.modelData.id, arrow.modelData.direction);
                                else
                                    KdeConnect.setStatus(device.modelData.id, arrow.modelData.why, false);
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 6
                    radius: 3
                    color: "#161b22"

                    Rectangle {
                        // Un dispositivo che non riporta la carica ha la barra
                        // vuota: zero non e' "scarico", e la riga sotto dice
                        // perche' manca.
                        width: device.battery ? parent.width * Math.max(0, Math.min(100, device.battery.percent)) / 100 : 0
                        height: parent.height
                        radius: 3
                        color: device.battery ? KdeConnect.batteryColor(device.battery.percent) : "#30363d"

                        Behavior on width {
                            NumberAnimation {
                                duration: 300
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                }

                Text {
                    Layout.preferredWidth: 52
                    horizontalAlignment: Text.AlignRight
                    color: "#c9d1d9"
                    font.pixelSize: 11
                    // Il fulmine e' l'unica differenza fra "sta scendendo" e
                    // "sta salendo", e sta in un carattere.
                    text: device.battery ? `${device.battery.percent}%` + (device.battery.charging ? " ⚡" : "") : "—"
                }
            }

            // Sotto: l'esito dell'ultima azione se ce n'e' una, altrimenti
            // dove sta il telefono o perche' la batteria manca. L'esito ha la
            // precedenza perche' e' la risposta a un clic appena dato.
            RowLayout {
                id: line

                Layout.fillWidth: true
                Layout.leftMargin: 4
                spacing: 5

                // Gli indirizzi si mostrano solo quando non c'e' niente di piu'
                // urgente da dire, ed e' l'unico caso in cui ha senso offrirne
                // la copia: un messaggio d'errore negli appunti non serve a
                // nessuno.
                readonly property string addresses: (device.modelData.addresses ?? []).join(", ")
                readonly property bool showingAddresses: !device.status && device.modelData.reachable && device.battery && addresses !== ""

                // torna da se' all'icona dopo aver confermato
                property bool copied: false

                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    font.pixelSize: 9

                    color: {
                        if (device.status)
                            return device.status.ok ? "#3fb950" : "#d29922";
                        return device.modelData.reachable ? "#6e7681" : "#484f58";
                    }

                    text: {
                        if (device.status)
                            return device.status.text;
                        if (!device.modelData.reachable)
                            return I18n.t("non raggiungibile");
                        if (!device.battery)
                            return root.reasonText(device.modelData.battery_unknown ?? "");
                        // Su quale rete risponde: meta' della risposta a
                        // "perche' non si collega" e' che il telefono e' su
                        // un'altra.
                        return line.addresses;
                    }
                }

                // Copia l'indirizzo: e' quello che si incolla in un ping, in un
                // `adb connect` o in una regola del firewall. Stesso gesto e
                // stessa conferma del pannello Rete.
                Text {
                    visible: line.showingAddresses
                    color: line.copied ? "#3fb950" : copyHover.hovered ? "#58a6ff" : "#484f58"
                    font.pixelSize: 10
                    text: line.copied ? "✓" : "⧉"

                    HoverHandler {
                        id: copyHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onSingleTapped: {
                            Quickshell.clipboardText = line.addresses;
                            line.copied = true;
                            copiedReset.restart();
                        }
                    }

                    Tooltip {
                        hovered: copyHover.hovered
                        text: I18n.t("Copia l'indirizzo")
                    }

                    Timer {
                        id: copiedReset

                        interval: 1200
                        onTriggered: line.copied = false
                    }
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true
        visible: KdeConnect.loaded && KdeConnect.paired.length === 0 && KdeConnect.lastError === ""
        wrapMode: Text.Wrap
        color: "#484f58"
        font.pixelSize: 10
        text: I18n.t("nessun dispositivo accoppiato")
    }

    Text {
        Layout.fillWidth: true
        visible: KdeConnect.lastError !== ""
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
        color: "#d29922"
        font.pixelSize: 9
        text: KdeConnect.lastError
    }
}
