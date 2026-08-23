import QtQuick
import QtQuick.Layouts
import Quickshell

// Chi sta usando la rete, processo per processo — quello che fa nethogs in
// terminale, ma dentro la dashboard.
//
// I dati arrivano dallo stesso campionamento della finestra processi (vedi
// Processes/procmon.py): il traffico per processo non e' in /proc, lo misura
// nethogs mettendosi in ascolto sulle interfacce.
Rectangle {
    id: win

    readonly property int metricWidth: 92
    // processo di cui si stanno guardando gli interlocutori: uno per volta,
    // altrimenti l'elenco diventa un muro
    property int expandedPid: 0

    // Aprire una riga vuol dire volerne sapere di piu': insieme agli indirizzi
    // si chiedono i dettagli del processo, gli stessi che mostra la finestra
    // Processi. Costano una lettura di /proc, e solo per il processo aperto.
    onExpandedPidChanged: Processes.describe(win.expandedPid)

    // Interfacce da nascondere. Non persistita in Settings: i nomi cambiano
    // da una sessione all'altra — un veth di un container si rigenera a ogni
    // riavvio — e salvarli sarebbe solo spazzatura in configurazione.
    property var hiddenIfaces: []

    // name | netSent | netReceived
    property string sortKey: "net"
    property bool sortDesc: true
    // Come nell'elenco processi: mentre il puntatore e' sulla lista l'ordine
    // resta fermo, altrimenti la riga che si sta per aprire scivola via.
    property bool frozen: false
    property var frozenOrder: []

    // Gli interlocutori di un processo che passano i due filtri. Sono separati
    // perche' rispondono a domande diverse: "cosa parla con se stesso" e "cosa
    // parla con il resto di casa".
    // "IT" -> 🇮🇹: le due lettere diventano i due "regional indicator" che il
    // font compone in una bandiera sola. Senza codice, niente bandiera.
    function flag(iso: string): string {
        if (!iso || iso.length !== 2)
            return "";
        const base = 0x1F1E6;
        return String.fromCodePoint(base + iso.charCodeAt(0) - 65) + String.fromCodePoint(base + iso.charCodeAt(1) - 65);
    }

    // Interlocutori pubblici che il database non sa collocare: sul globo non
    // possono comparire, ma esistono e vanno detti.
    readonly property var unlocated: {
        const seen = {};
        for (const process of Processes.networkUsers) {
            for (const peer of win.peersOf(process)) {
                if (peer.scope !== "public" || (peer.lat !== undefined && peer.lat !== null))
                    continue;
                const found = seen[peer.ip];
                if (found) {
                    if (!found.services.includes(process.name))
                        found.services.push(process.name);
                } else {
                    seen[peer.ip] = {
                        ip: peer.ip,
                        name: peer.name ?? "",
                        services: [process.name]
                    };
                }
            }
        }
        return Object.values(seen);
    }

    function peersOf(process: var): var {
        return (process.peers ?? []).filter(peer => {
            if (Settings.netHideLoopback && peer.scope === "loopback")
                return false;
            if (Settings.netHideLan && peer.scope === "lan")
                return false;
            if (win.hiddenIfaces.includes(peer.iface))
                return false;
            return true;
        });
    }

    // I pulsanti del filtro per interfaccia: [{ name, count }].
    //
    // Due sorgenti diverse, perche' rispondono a due domande diverse. Le
    // connessioni attribuite dicono cosa si puo' filtrare; le interfacce che
    // portano traffico dicono cosa esiste. Un veth di container sta solo nella
    // seconda — il traffico e' di processi che vivono in un altro namespace di
    // rete, e da qui non si vedono — e va detto lo stesso, altrimenti sembra
    // che quell'interfaccia non ci sia.
    //
    // `lo` resta fuori da entrambe: il traffico con se stessi ha gia' il suo
    // filtro qui sopra, e un secondo modo per nascondere la stessa cosa e' solo
    // un'occasione per contraddirsi.
    readonly property var ifaceFilters: {
        const counts = ({});
        const attributed = Processes.connectionInterfaces;
        for (const name in attributed)
            if (name !== "lo")
                counts[name] = attributed[name];
        for (const name of (SystemStats.net.interfaces ?? []))
            if (name !== "lo" && counts[name] === undefined)
                counts[name] = 0;
        return Object.keys(counts).sort().map(name => ({
                    name: name,
                    count: counts[name]
                }));
    }

    function toggleIface(name: string) {
        const next = win.hiddenIfaces.slice();
        const at = next.indexOf(name);
        if (at >= 0)
            next.splice(at, 1);
        else
            next.push(name);
        win.hiddenIfaces = next;
    }

    readonly property var rows: {
        // Un processo resta in elenco se gli restano interlocutori da mostrare.
        //
        // L'unica eccezione e' chi trasmette senza che si sappia con chi: niente
        // connessioni TCP stabilite (traffico UDP, oppure un processo di cui non
        // possiamo leggere i descrittori). Quel traffico non e' classificabile,
        // e nasconderlo in base a un filtro che non lo riguarda sarebbe peggio
        // che mostrarlo. Chi invece ha connessioni note, tutte filtrate via,
        // sparisce: nethogs misura sulle interfacce, quindi anche il traffico
        // verso la rete locale e' suo traffico — non e' una ragione per restare.
        const list = Processes.networkUsers.filter(p => win.peersOf(p).length > 0 || ((p.conns ?? 0) === 0 && (p.net ?? 0) > 0));
        if (win.frozen && win.frozenOrder.length) {
            const rank = {};
            for (let i = 0; i < win.frozenOrder.length; i++)
                rank[win.frozenOrder[i]] = i;
            list.sort((a, b) => (rank[a.pid] ?? 99999) - (rank[b.pid] ?? 99999));
            return list;
        }
        const sign = win.sortDesc ? -1 : 1;
        list.sort((a, b) => {
            if (win.sortKey === "name")
                return sign * a.name.localeCompare(b.name);
            return sign * ((a[win.sortKey] ?? 0) - (b[win.sortKey] ?? 0));
        });
        return list;
    }

    function sortBy(key: string) {
        win.frozen = false;
        if (win.sortKey === key)
            win.sortDesc = !win.sortDesc;
        else {
            win.sortKey = key;
            win.sortDesc = key !== "name";
        }
    }

    function setFrozen(value: bool) {
        if (value === win.frozen)
            return;
        if (value)
            win.frozenOrder = win.rows.map(p => p.pid);
        win.frozen = value;
    }

    // Tutti gli interlocutori geolocalizzati, con accanto il processo che li ha
    // aperti: il globo li mostra insieme e mette in evidenza quelli della riga
    // aperta nell'elenco.
    readonly property var located: {
        const out = [];
        for (const process of Processes.networkUsers) {
            for (const peer of (process.peers ?? [])) {
                if (peer.lat === undefined || peer.lat === null)
                    continue;
                out.push({
                    lat: peer.lat,
                    lon: peer.lon,
                    ip: peer.ip,
                    name: peer.name ?? "",
                    country: peer.country ?? "",
                    approx: peer.approx ?? false,
                    iso: peer.iso ?? "",
                    radius: peer.radius ?? 0,
                    pid: process.pid,
                    process: process.name,
                    bytes: process.net ?? 0
                });
            }
        }
        return out;
    }

    readonly property var countries: {
        const seen = {};
        for (const host of win.located) {
            if (!host.country.length)
                continue;
            const found = seen[host.country];
            if (found)
                found.count++;
            else
                seen[host.country] = {
                    name: host.country,
                    iso: host.iso ?? "",
                    count: 1
                };
        }
        return Object.keys(seen).sort().map(name => seen[name]);
    }

    implicitWidth: 1000
    // Quanto vuole essere alto: la colonna piu' alta piu' i margini. Con un
    // numero fisso la finestra nasceva alta quanto il globo e tagliava via la
    // legenda dei paesi che gli sta sotto.
    implicitHeight: columns.implicitHeight + 24
    color: "#0d1117"

    RowLayout {
        id: columns

        anchors.fill: parent
        anchors.margins: 12
        spacing: 14

    ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: 10

        // ------------------------------------------------- totale di sistema
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                color: "#c9d1d9"
                font.pixelSize: 13
                // Una sola interfaccia, quella a cui si riferiscono i numeri
                // qui accanto. Elencarle tutte voleva dire una riga che
                // cambiava a ogni campione, perche' bridge e veth stanno
                // fermi per un ciclo e poi ripartono.
                text: I18n.t("Rete") + ` · ${SystemStats.net.iface}`
            }

            Text {
                color: "#58a6ff"
                font.pixelSize: 13
                font.bold: true
                text: `↓ ${SystemStats.formatBytes(SystemStats.net.rx, true)}`
            }

            Text {
                color: "#db6d28"
                font.pixelSize: 13
                font.bold: true
                text: `↑ ${SystemStats.formatBytes(SystemStats.net.tx, true)}`
            }
        }

        Sparkline {
            Layout.fillWidth: true
            implicitHeight: 54
            maxValue: SystemStats.netScale
            values: SystemStats.netRxHistory
            lineColor: Settings.colorFor("netRx", "#58a6ff")
            values2: SystemStats.netTxHistory
            lineColor2: Settings.colorFor("netTx", "#db6d28")
        }

        // ------------------------------------------------------- due filtri
        // Separati perche' rispondono a domande diverse: "nascondi il dialogo
        // della macchina con se stessa" non e' "nascondi il dialogo con il
        // resto di casa", e chi indaga sul traffico verso internet in genere
        // vuole spegnere l'uno o l'altro, non entrambi insieme.
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 2
            spacing: 6

            Repeater {
                model: [
                    {
                        key: "loopback",
                        label: I18n.t("nascondi localhost"),
                        active: Settings.netHideLoopback
                    },
                    {
                        key: "lan",
                        label: I18n.t("nascondi rete locale"),
                        active: Settings.netHideLan
                    }
                ]

                Rectangle {
                    id: filterButton

                    required property var modelData

                    Layout.fillWidth: true
                    implicitHeight: 24
                    radius: 6
                    // acceso = filtro attivo, cioe' qualcosa non si sta vedendo:
                    // il colore lo dichiara invece di lasciarlo intuire da un
                    // elenco piu' corto
                    color: filterButton.modelData.active ? "#21262d" : "transparent"
                    border.width: 1
                    border.color: filterButton.modelData.active ? "#d29922" : "#30363d"

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 5

                        Text {
                            color: filterButton.modelData.active ? "#d29922" : "#484f58"
                            font.pixelSize: 10
                            text: filterButton.modelData.active ? "◉" : "○"
                        }

                        Text {
                            color: filterButton.modelData.active ? "#d29922" : "#6e7681"
                            font.pixelSize: 10
                            text: filterButton.modelData.label
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Settings.toggleNetFilter(filterButton.modelData.key)
                    }
                }
            }
        }

        // -------------------------------------------------- filtro interfacce
        // Compare solo con almeno due interfacce — con una sola non ci sarebbe
        // niente da filtrare. E' cosi' che una VPN o il veth di un container si
        // isolano dal resto, senza doverli conoscere per nome in anticipo.
        RowLayout {
            Layout.fillWidth: true
            visible: win.ifaceFilters.length > 1
            spacing: 6

            Text {
                color: "#484f58"
                font.pixelSize: 9
                text: I18n.t("interfaccia")
            }

            Repeater {
                model: win.ifaceFilters

                Rectangle {
                    id: ifaceChip

                    required property var modelData

                    // senza connessioni attribuite non c'e' niente da
                    // nascondere: il pulsante resta a dire che l'interfaccia
                    // esiste, ma non reagisce — e il conteggio a zero accanto
                    // spiega da solo il perche'
                    readonly property bool usable: ifaceChip.modelData.count > 0
                    readonly property bool shown: !win.hiddenIfaces.includes(ifaceChip.modelData.name)

                    implicitWidth: ifaceLabel.implicitWidth + 16
                    implicitHeight: 22
                    radius: 6
                    color: ifaceChip.usable && ifaceChip.shown ? "#21262d" : "transparent"
                    border.width: 1
                    border.color: !ifaceChip.usable ? "#21262d" : ifaceChip.shown ? "#58a6ff" : "#30363d"
                    opacity: !ifaceChip.usable ? 0.45 : ifaceChip.shown ? 1 : 0.5

                    Text {
                        id: ifaceLabel

                        anchors.centerIn: parent
                        color: !ifaceChip.usable ? "#484f58" : ifaceChip.shown ? "#58a6ff" : "#484f58"
                        font.pixelSize: 10
                        font.family: "monospace"
                        text: `${ifaceChip.modelData.name} · ${ifaceChip.modelData.count}`
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: ifaceChip.usable
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.toggleIface(ifaceChip.modelData.name)
                    }
                }
            }

            Item {
                Layout.fillWidth: true
            }
        }

        // ---------------------------------------------- intestazioni colonne
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            Layout.leftMargin: 10
            Layout.rightMargin: 8
            spacing: 6

            Text {
                readonly property bool current: win.sortKey === "name"

                Layout.fillWidth: true
                // la colonna ordinata si riconosce dal grassetto piu' che dal
                // colore: inviati e ricevuti hanno gia' il loro, e cambiarlo
                // toglierebbe il colpo d'occhio su quale banda e' quale
                color: current ? "#c9d1d9" : "#6e7681"
                font.pixelSize: 10
                font.bold: current
                font.letterSpacing: 1
                text: I18n.t("PROCESSO") + (current ? (win.sortDesc ? " ↓" : " ↑") : "")

                TapHandler {
                    onTapped: win.sortBy("name")
                }

                HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                }
            }

            Text {
                readonly property bool current: win.sortKey === "netSent"

                Layout.preferredWidth: win.metricWidth
                horizontalAlignment: Text.AlignRight
                color: "#db6d28"
                font.pixelSize: 10
                font.bold: current
                font.letterSpacing: 1
                text: I18n.t("INVIATI") + (current ? (win.sortDesc ? " ↓" : " ↑") : "")

                TapHandler {
                    onTapped: win.sortBy("netSent")
                }

                HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                }
            }

            Text {
                readonly property bool current: win.sortKey === "netReceived"

                Layout.preferredWidth: win.metricWidth
                horizontalAlignment: Text.AlignRight
                color: "#58a6ff"
                font.pixelSize: 10
                font.bold: current
                font.letterSpacing: 1
                text: I18n.t("RICEVUTI") + (current ? (win.sortDesc ? " ↓" : " ↑") : "")

                TapHandler {
                    onTapped: win.sortBy("netReceived")
                }

                HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                }
            }
        }

        ListView {
            id: list

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: win.rows
            spacing: 1
            boundsBehavior: Flickable.StopAtBounds

            HoverHandler {
                onHoveredChanged: win.setFrozen(hovered)
            }

            delegate: Rectangle {
                id: row

                required property var modelData

                readonly property var peers: win.peersOf(row.modelData)
                readonly property bool expanded: win.expandedPid === row.modelData.pid

                width: list.width
                // espansa mostra un rigo per interlocutore, sotto l'intestazione
                // 38 di riga, piu' quanto misura davvero il blocco aperto.
                // Stimare "otto righe da tredici pixel" lasciava fuori l'ultimo
                // indirizzo: il numero di righe cambia col processo (eseguibile
                // e cartella non ci sono sempre) e i caratteri non sono alti
                // quanto si crede.
                implicitHeight: 38 + (row.expanded ? expandedBlock.implicitHeight + 14 : 0)
                radius: 6
                color: row.expanded ? "#161b22" : rowHover.hovered ? "#161b22" : "transparent"
                clip: true

                HoverHandler {
                    id: rowHover
                }

                TapHandler {
                    onTapped: win.expandedPid = row.expanded ? 0 : row.modelData.pid
                }

                RowLayout {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: 38
                    anchors.leftMargin: 10
                    anchors.rightMargin: 8
                    spacing: 6

                    Text {
                        // il triangolo dice che c'e' altro sotto; spento se
                        // non si sa con chi sta parlando (processo di un altro
                        // utente: i suoi descrittori non sono leggibili)
                        color: row.peers.length > 0 ? "#6e7681" : "#21262d"
                        font.pixelSize: 9
                        text: row.expanded ? "▾" : "▸"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                elide: Text.ElideRight
                                color: "#c9d1d9"
                                font.pixelSize: 12
                                text: row.modelData.name
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: row.peers.length > 0
                                color: "#6e7681"
                                font.pixelSize: 9
                                text: I18n.tn(row.peers.length, "1 connessione", "%1 connessioni")
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            color: "#484f58"
                            font.pixelSize: 9
                            font.family: "monospace"
                            text: `${row.modelData.pid} · ${row.modelData.cmdline}`
                        }
                    }

                    Text {
                        Layout.preferredWidth: win.metricWidth
                        horizontalAlignment: Text.AlignRight
                        color: row.modelData.netSent > 0 ? "#db6d28" : "#484f58"
                        font.pixelSize: 11
                        text: SystemStats.formatBytes(row.modelData.netSent, true)
                    }

                    Text {
                        Layout.preferredWidth: win.metricWidth
                        horizontalAlignment: Text.AlignRight
                        color: row.modelData.netReceived > 0 ? "#58a6ff" : "#484f58"
                        font.pixelSize: 11
                        text: SystemStats.formatBytes(row.modelData.netReceived, true)
                    }
                }

                // --- informazioni del processo, poi con chi sta parlando ---
                ColumnLayout {
                    id: expandedBlock

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.topMargin: 36
                    anchors.leftMargin: 28
                    anchors.rightMargin: 12
                    visible: row.expanded
                    spacing: 0

                    ProcInfo {
                        Layout.fillWidth: true
                        Layout.bottomMargin: 4
                        labelWidth: 84
                        // i dettagli sono quelli del processo aperto: se nel
                        // frattempo il puntatore ne ha chiesti altri, meglio
                        // niente che le informazioni di un estraneo
                        info: Processes.detail && Processes.detail.pid === row.modelData.pid ? Processes.detail : null
                    }

                    Repeater {
                        model: row.expanded ? row.peers : []

                        RowLayout {
                            id: peer

                            required property var modelData

                            // torna da se' all'icona dopo aver confermato
                            property bool copied: false

                            Layout.fillWidth: true
                            Layout.preferredHeight: 17
                            spacing: 6

                            // Copia l'indirizzo, non il nome: e' quello che si
                            // incolla in un ping, in un whois o in una regola
                            // del firewall.
                            Text {
                                color: peer.copied ? "#3fb950" : copyHover.hovered ? "#58a6ff" : "#484f58"
                                font.pixelSize: 10
                                text: peer.copied ? "✓" : "⧉"

                                HoverHandler {
                                    id: copyHover

                                    cursorShape: Qt.PointingHandCursor
                                }

                                TapHandler {
                                    onTapped: {
                                        Quickshell.clipboardText = peer.modelData.ip;
                                        peer.copied = true;
                                        copiedReset.restart();
                                    }
                                }

                                Timer {
                                    id: copiedReset

                                    interval: 1200
                                    onTriggered: peer.copied = false
                                }
                            }

                            // La bandiera del paese, accanto al pulsante di
                            // copia: dice la provenienza senza rubare spazio al
                            // nome. Vuota per la rete locale e per chi il
                            // database non sa collocare.
                            Text {
                                Layout.preferredWidth: 14
                                horizontalAlignment: Text.AlignHCenter
                                font.pixelSize: 10
                                text: win.flag(peer.modelData.iso ?? "")
                            }

                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                color: "#8b949e"
                                font.pixelSize: 10
                                font.family: "monospace"
                                // il nome se il DNS inverso lo ha dato, altrimenti
                                // l'indirizzo: il nome arriva in sottofondo e la
                                // riga si aggiorna da sola al campione dopo
                                text: peer.modelData.name.length > 0 ? peer.modelData.name : peer.modelData.ip
                            }

                            Text {
                                visible: peer.modelData.count > 1
                                color: "#6e7681"
                                font.pixelSize: 9
                                text: `×${peer.modelData.count}`
                            }

                            Text {
                                color: "#484f58"
                                font.pixelSize: 10
                                font.family: "monospace"
                                text: `:${peer.modelData.port}`
                            }
                        }
                    }
                }
            }

            ScrollBar {
                anchors.right: parent.right
                height: parent.height
                view: list
            }

            Text {
                anchors.centerIn: parent
                width: parent.width - 40
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                visible: list.count === 0
                color: "#484f58"
                font.pixelSize: 12
                text: Processes.netAvailable ? I18n.t("nessun processo sta usando la rete in questo momento") : I18n.t("traffico per processo non disponibile")
            }
        }

        Text {
            Layout.fillWidth: true
            visible: !Processes.netAvailable
            wrapMode: Text.Wrap
            color: "#6e7681"
            font.pixelSize: 9
            font.family: "monospace"
            text: Processes.netError
        }

        // Le connessioni che il kernel elenca ma che nessun processo rivendica
        // sono quelle di root e degli altri utenti. Senza dirlo, questa finestra
        // sembrerebbe l'elenco completo mentre e' solo la propria meta'.
        FixHint {
            Layout.fillWidth: true
            Layout.topMargin: 4
            visible: Processes.orphanConns > 0
            headline: I18n.tn(Processes.orphanConns, "1 connessione senza processo", "%1 connessioni senza processo")
            explanation: Processes.connError
            command: Processes.connFix
        }
    }

        // ======================================================= il globo
        ColumnLayout {
            Layout.preferredWidth: 340
            Layout.fillHeight: true
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    color: "#8b949e"
                    font.pixelSize: 10
                    font.letterSpacing: 1
                    text: I18n.t("DOVE SONO GLI HOST")
                }

                // Due inquadrature, due intenzioni diverse: "dove sono io" e
                // "dove sono loro". Ritrovare un punto a mano su una sfera non
                // e' immediato, quindi entrambe meritano un pulsante.
                Rectangle {
                    implicitWidth: 22
                    implicitHeight: 20
                    radius: 4
                    color: homeHover.hovered ? "#21262d" : "transparent"
                    border.width: 1
                    border.color: "#30363d"

                    HoverHandler {
                        id: homeHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    Text {
                        anchors.centerIn: parent
                        color: "#3fb950"
                        font.pixelSize: 10
                        text: "⌖"
                    }

                    TapHandler {
                        onTapped: globe.centerOnObserver()
                    }
                }

                Rectangle {
                    implicitWidth: 22
                    implicitHeight: 20
                    radius: 4
                    color: framedHover.hovered ? "#21262d" : "transparent"
                    border.width: 1
                    // acceso quando l'inquadratura e' quella automatica: dice
                    // che il globo si sta sistemando da se'
                    border.color: globe.userMoved ? "#30363d" : "#388bfd"

                    HoverHandler {
                        id: framedHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    Text {
                        anchors.centerIn: parent
                        color: globe.userMoved ? "#6e7681" : "#58a6ff"
                        font.pixelSize: 10
                        text: "◎"
                    }

                    TapHandler {
                        onTapped: globe.frameHosts(true)
                    }
                }
            }

            WorldGlobe {
                id: globe

                Layout.fillWidth: true
                Layout.preferredHeight: width
                hosts: win.located
                highlightPid: win.expandedPid
                // con una VPN accesa l'osservatore si sposta dove riemerge il
                // traffico: vedi vpnExit
                exitKnown: Processes.vpnExit !== null
                exitLat: Processes.vpnExit ? Processes.vpnExit.lat : 0
                exitLon: Processes.vpnExit ? Processes.vpnExit.lon : 0
            }

            // Un database vecchio mette gli host nel paese sbagliato, e non c'e'
            // modo di accorgersene guardando il globo: va detto qui.
            FixHint {
                Layout.fillWidth: true
                Layout.topMargin: 4
                visible: Processes.geoError.length > 0
                headline: I18n.t("posizioni poco affidabili")
                explanation: Processes.geoError
                command: Processes.geoFix
            }

            // Dove il mondo ci vede, quando non e' dove siamo. Detto a parole
            // perche' un punto ambra su un altro continente, da solo, sembra un
            // errore di geolocalizzazione invece del funzionamento della VPN.
            Text {
                Layout.fillWidth: true
                visible: Processes.vpnExit !== null
                wrapMode: Text.Wrap
                color: "#d29922"
                font.pixelSize: 10
                text: {
                    const exit = Processes.vpnExit;
                    if (!exit)
                        return "";
                    const where = exit.city && exit.city.length > 0 ? `${exit.city}, ${exit.country}` : exit.country;
                    return `${win.flag(exit.iso ?? "")} ` + I18n.t("in uscita da %1 via %2").arg(where).arg(exit.iface);
                }
            }

            Text {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#484f58"
                font.pixelSize: 9
                text: win.located.length === 0 ? I18n.t("nessun host geolocalizzato: le connessioni sono tutte sulla rete locale") : I18n.t("trascina per girare il globo · i cerchi vuoti sono posizioni note solo per nazione")
            }

            // --- paesi contattati ---
            Flickable {
                id: legend

                Layout.fillWidth: true
                Layout.fillHeight: true
                // riempire lo spazio disponibile non e' chiederne: senza un
                // minimo, nel calcolo dell'altezza naturale la legenda pesa
                // zero e la finestra nasce senza posto per lei
                Layout.minimumHeight: 150
                contentHeight: legendColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: legendColumn

                    width: legend.width
                    spacing: 1

                    // --- host che il database non sa collocare ---
                    // Non compaiono sul globo: senza coordinate non c'e' un
                    // punto da disegnare. Elencarli qui evita che spariscano
                    // dalla vista solo perche' MaxMind non li conosce.
                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        visible: win.unlocated.length > 0
                        color: "#6e7681"
                        font.pixelSize: 9
                        font.letterSpacing: 1
                        text: I18n.t("SENZA POSIZIONE")
                    }

                    Repeater {
                        model: win.unlocated

                        RowLayout {
                            id: unknownHost

                            required property var modelData

                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                color: "#484f58"
                                font.pixelSize: 10
                                text: "?"
                            }

                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                color: "#8b949e"
                                font.pixelSize: 9
                                font.family: "monospace"
                                text: unknownHost.modelData.name.length > 0 ? unknownHost.modelData.name : unknownHost.modelData.ip
                            }

                            Text {
                                color: "#6e7681"
                                font.pixelSize: 9
                                text: unknownHost.modelData.services.slice(0, 2).join(", ")
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        visible: win.countries.length > 0
                        color: "#6e7681"
                        font.pixelSize: 9
                        font.letterSpacing: 1
                        text: I18n.t("PAESI")
                    }

                    Repeater {
                        model: win.countries

                        RowLayout {
                            id: country

                            required property var modelData

                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                font.pixelSize: 10
                                text: win.flag(country.modelData.iso)
                            }

                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                color: "#8b949e"
                                font.pixelSize: 10
                                text: country.modelData.name
                            }

                            Text {
                                color: "#6e7681"
                                font.pixelSize: 9
                                text: I18n.tn(country.modelData.count, "1 host", "%1 host")
                            }
                        }
                    }
                }

                ScrollBar {
                    anchors.right: parent.right
                    height: parent.height
                    view: legend
                }
            }
        }
    }
}
