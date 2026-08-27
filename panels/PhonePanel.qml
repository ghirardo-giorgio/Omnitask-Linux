import QtQuick
import QtQuick.Layouts
import Quickshell

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

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

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "phones"
    property string panelTitle: "Telefoni"

    spacing: 6

    Component.onCompleted: {
        KdeConnect.watch();
        // Lo stato ADB non lo tiene nessuno: si guarda all'accensione del
        // pannello e poi al ritmo di tutto il resto.
        PhoneAdb.peek();
    }

    Component.onDestruction: KdeConnect.unwatch()

    // Lo stesso giro della batteria, per la stessa ragione: un collegamento
    // che cade non lo annuncia nessuno, e trenta secondi di ritardo su un
    // pallino sono ritardo che non si nota. Costa un `adb devices` — niente
    // ascolto mDNS, che qui sarebbe dieci volte tanto per la stessa risposta.
    Timer {
        interval: KdeConnect.pollInterval
        running: true
        repeat: true
        onTriggered: PhoneAdb.peek()
    }

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

    // Una targhetta di stato: tre lettere e un colore.
    //
    // Verde acceso, rosso spento, ambra "c'e' ma non e' utilizzabile", grigio
    // "non lo so ancora". Sono tre lettere e non un pallino perche' i pallini
    // qui sono due e uno accanto all'altro non si distinguerebbero: chi guarda
    // deve sapere *quale* dei due collegamenti manca, che e' tutto il punto.
    component Badge: Rectangle {
        id: badge

        required property string label
        // "on", "off", "half", "unknown"
        // Non `state`: quello e' gia' di Item, ed e' la macchina a stati
        // delle transizioni. Un giorno qualcuno ne aggiungerebbe una a
        // questo rettangolo e se la troverebbe agganciata a "on"/"off".
        required property string linkState
        property string hint: ""

        readonly property color tint: {
            switch (badge.linkState) {
            case "on":
                return "#3fb950";
            case "off":
                return "#f85149";
            case "half":
                return "#d29922";
            }
            return "#484f58";
        }

        implicitWidth: mark.implicitWidth + 10
        implicitHeight: 13
        radius: 3
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(badge.tint.r, badge.tint.g, badge.tint.b, 0.45)

        Text {
            id: mark

            anchors.centerIn: parent
            color: badge.tint
            font.pixelSize: 8
            text: badge.label
        }

        HoverHandler {
            id: badgeHover
        }

        Tooltip {
            hovered: badgeHover.hovered
            text: badge.hint
        }
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

            // L'esito del collegamento torna qui e non nella finestra: e'
            // partito da questa riga, ed e' sotto questo nome che il pannello
            // scrive gia' com'e' andata coi tasti degli appunti.
            Connections {
                target: PhoneAdb

                function onConnectDone(name: string, ok: bool, text: string): void {
                    if (name === device.modelData.name)
                        KdeConnect.setStatus(device.modelData.id, text, ok);
                }
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

                readonly property string addresses: (device.modelData.addresses ?? []).join(", ")

                // Lo stato ADB di questo telefono, o null finche' non si sa.
                // Per nome, e in mancanza per indirizzo: un telefono col cavo
                // attaccato che KDE Connect non raggiunge ha comunque lo
                // stesso nome nei due elenchi, ma la ricerca per indirizzo
                // copre il caso in cui non ce l'abbia.
                readonly property var adb: PhoneAdb.link(device.modelData.name)
                    ?? (line.addresses !== "" ? PhoneAdb.link((device.modelData.addresses ?? [])[0] ?? "") : null)

                // Quello che c'e' da dire sotto il nome. Calcolato una volta
                // perche' lo guardano in due: il testo e il tasto di copia, che
                // ha senso solo se quel testo e' un indirizzo — un messaggio
                // d'errore negli appunti non serve a nessuno.
                //
                // «Non raggiungibile» non c'e' piu' fra i casi: adesso lo dice
                // la targhetta KDE, in rosso, e ripeterlo a parole toglierebbe
                // il posto all'indirizzo — che e' proprio quello che serve
                // quando si sta cercando di capire perche' non si collega.
                readonly property string detail: {
                    if (device.status)
                        return device.status.text;
                    if (device.modelData.reachable && !device.battery)
                        return root.reasonText(device.modelData.battery_unknown ?? "");
                    return line.addresses;
                }

                readonly property bool showingAddresses: !device.status
                    && line.detail === line.addresses && line.addresses !== ""

                // torna da se' all'icona dopo aver confermato
                property bool copied: false

                // I due collegamenti, separati perche' sono separati davvero.
                // Restano tutti e due sempre a video: quello acceso conferma,
                // quello spento dice cosa accendere, e uno che sparisce
                // lascerebbe credere che non esista.
                Badge {
                    label: "ADB"
                    linkState: {
                        if (!PhoneAdb.linksKnown || !line.adb)
                            return "unknown";
                        if (line.adb.connected)
                            return "on";
                        if (line.adb.adb !== "")
                            return "half";
                        return "off";
                    }
                    hint: {
                        if (!PhoneAdb.linksKnown)
                            return I18n.t("lettura…");
                        if (line.adb && line.adb.connected)
                            return line.adb.via === "usb"
                                ? I18n.t("ADB collegato col cavo")
                                : I18n.t("ADB collegato senza fili");
                        if (line.adb && line.adb.adb === "unauthorized")
                            return I18n.t("ADB: conferma la richiesta sullo schermo del telefono, o riassocia con ⚯");
                        if (line.adb && line.adb.adb !== "")
                            return I18n.t("ADB: collegamento fermo (%1)").arg(line.adb.adb);
                        return I18n.t("ADB non collegato: accendi Debug wireless sul telefono, poi apri la sua finestra e premi Collega");
                    }
                }

                Badge {
                    label: "KDE"
                    linkState: {
                        if (!KdeConnect.loaded)
                            return "unknown";
                        return device.modelData.reachable ? "on" : "off";
                    }
                    hint: device.modelData.reachable
                        ? I18n.t("KDE Connect collegato")
                        : I18n.t("KDE Connect non risponde: apri l'app sul telefono e controlla che sia sulla stessa rete")
                }

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

                    text: line.detail
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

                // Collega: una sessione ADB senza fili cade da se' — basta
                // che il telefono dorma o che il Wi-Fi si assopisca — mentre
                // il debug resta acceso, ed e' un comando solo a rimetterla in
                // piedi. Sta qui perche' qui si vede la targhetta ADB rossa:
                // aprire la finestra per premere «Collega» sarebbe passare da
                // un'altra stanza per accendere questa luce.
                //
                // Le due frecce affiancate e non gli anelli: quelli qui
                // accanto vogliono gia' dire «riassocia», e due glifi che si
                // somigliano per due azioni diverse sono un glifo sbagliato
                // premuto meta' delle volte. Orizzontali, che le distingue
                // dalle frecce degli appunti nella riga sopra.
                Text {
                    id: plug

                    // Un telefono gia' collegato non ha niente da collegare.
                    // Spenta e non nascosta, come le frecce degli appunti: al
                    // clic dice perche' invece di sparire.
                    readonly property bool linked: line.adb !== null && (line.adb.connected ?? false)
                    readonly property bool working: PhoneAdb.connecting === device.modelData.name

                    color: {
                        if (plug.working)
                            return "#d29922";
                        if (plug.linked)
                            return "#30363d";
                        return plugHover.hovered ? "#58a6ff" : "#484f58";
                    }
                    font.pixelSize: 10
                    text: "⇌"

                    HoverHandler {
                        id: plugHover

                        cursorShape: plug.linked || plug.working ? Qt.ArrowCursor : Qt.PointingHandCursor
                    }

                    TapHandler {
                        onSingleTapped: {
                            if (plug.working)
                                return;

                            if (plug.linked) {
                                KdeConnect.setStatus(device.modelData.id, I18n.t("ADB e' gia' collegato"), true);
                                return;
                            }

                            // Il collegamento puo' prendere qualche secondo —
                            // l'ascolto dell'annuncio, i tentativi porta per
                            // porta — e senza una parola subito il clic
                            // sembrerebbe non aver fatto niente.
                            KdeConnect.setStatus(device.modelData.id, I18n.t("collegamento…"), true);
                            PhoneAdb.connectPhone(device.modelData.name);
                        }
                    }

                    Tooltip {
                        hovered: plugHover.hovered
                        text: plug.linked ? I18n.t("ADB e' gia' collegato")
                            : I18n.t("Collega ADB senza fili")
                    }
                }

                // Riassocia: per quando e' il telefono a togliere
                // l'autorizzazione — la chiave del debug USB revocata, o
                // questo PC dimenticato fra i dispositivi accoppiati del debug
                // wireless. Da qui non si puo' fare niente di piu' che aprire
                // la finestra: le sei cifre del nuovo accoppiamento vanno
                // lette sul telefono e digitate, e in una riga alta dieci
                // pixel non c'e' posto per una conversazione.
                //
                // Sempre presente, come le frecce degli appunti: un pulsante
                // che compare solo nei guai e' un pulsante che nei guai non si
                // sa di avere.
                //
                // Gli anelli intrecciati e non la freccia circolare: quella
                // nella dashboard vuol dire gia' «rileggi», e qui accanto a
                // «Aggiorna» sarebbe la stessa parola per due cose diverse.
                Text {
                    color: repairHover.hovered ? "#58a6ff" : "#484f58"
                    font.pixelSize: 10
                    text: "⚯"

                    HoverHandler {
                        id: repairHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onSingleTapped: DashActions.repairPhone(device.modelData.name)
                    }

                    Tooltip {
                        hovered: repairHover.hovered
                        text: I18n.t("Riassocia: il telefono ha tolto l'autorizzazione")
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
