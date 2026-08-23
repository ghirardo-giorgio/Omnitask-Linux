import QtQuick
import QtQuick.Layouts
import Quickshell

// Contenuto della finestra Hardware, separato dalla finestra che lo ospita
// (stesso schema di ServicesPanel.qml).
//
// Le categorie non sono schede vere: ognuna produce lo stesso tipo di righe —
// una voce con due valori, oppure un dispositivo con sotto il suo driver — e
// un solo delegate le disegna tutte. Serve a non riscrivere otto volte la
// stessa riga, e fa si' che aggiungere una categoria voglia dire scrivere una
// funzione che restituisce righe, non un pezzo di interfaccia.
Rectangle {
    id: win

    property string category: "sistema"
    property string query: ""

    readonly property var categories: [
        {
            id: "sistema",
            label: "Sistema"
        },
        {
            id: "memoria",
            label: "Memoria"
        },
        {
            id: "grafica",
            label: "Grafica"
        },
        {
            id: "audio",
            label: "Audio"
        },
        {
            id: "rete",
            label: "Rete"
        },
        {
            id: "dischi",
            label: "Dischi"
        },
        {
            id: "usb",
            label: "USB"
        },
        {
            id: "pci",
            label: "PCI"
        }
    ]

    // Le righe della categoria scelta, gia' filtrate dalla ricerca. La ricerca
    // guarda tutto il testo della riga: cercare "nvidia" deve trovare la scheda
    // sia che il nome stia nel titolo sia che stia nel driver.
    readonly property var rows: {
        const all = win.build(win.category);
        const q = win.query.trim().toLowerCase();
        if (q === "")
            return all;
        return all.filter(row => {
            if (row.kind === "section")
                return false;
            return [row.label, row.value, row.title, row.subtitle, row.badge].filter(t => t !== undefined).join(" ").toLowerCase().includes(q);
        });
    }

    implicitWidth: 720
    implicitHeight: 660
    color: "#0d1117"

    Component.onCompleted: Hardware.ensure()

    // ------------------------------------------------------------- costruttori

    function spec(label: string, value: var): var {
        return {
            kind: "spec",
            label: label,
            value: (value === undefined || value === null || value === "") ? "—" : String(value)
        };
    }

    function section(label: string): var {
        return {
            kind: "section",
            label: label
        };
    }

    function device(title: string, subtitle: string, badge: string, tone: string): var {
        return {
            kind: "device",
            title: title,
            subtitle: subtitle,
            badge: badge,
            tone: tone ?? ""
        };
    }

    function build(which: string): var {
        switch (which) {
        case "sistema":
            return win.systemRows();
        case "memoria":
            return win.memoryRows();
        case "grafica":
            return win.graphicsRows();
        case "audio":
            return win.audioRows();
        case "rete":
            return win.networkRows();
        case "dischi":
            return win.storageRows();
        case "usb":
            return win.usbRows();
        case "pci":
            return win.pciRows();
        }
        return [];
    }

    function systemRows(): var {
        const board = Hardware.board ?? ({});
        const bios = board.bios ?? ({});
        const cpu = Hardware.cpu ?? ({});
        const out = [];

        out.push(win.section(I18n.t("Scheda madre")));
        out.push(win.spec(I18n.t("Modello"), board.model));
        out.push(win.spec(I18n.t("Produttore"), board.vendor));
        if (board.family)
            out.push(win.spec(I18n.t("Famiglia"), board.family));
        out.push(win.spec(I18n.t("Telaio"), board.chassis));
        out.push(win.spec("BIOS", [bios.vendor, bios.version, bios.date].filter(t => t).join(" · ")));

        out.push(win.section(I18n.t("Processore")));
        out.push(win.spec(I18n.t("Modello"), Hardware.trimCpu(cpu.model)));
        out.push(win.spec(I18n.t("Core"), cpu.cores ? I18n.t("%1 core, %2 thread").arg(cpu.cores).arg(cpu.threads ?? cpu.cores) : null));
        // Le frequenze arrivano col decimale: 4665.835 MHz e' esatto e
        // illeggibile, e nessuno confronta un processore al kilohertz.
        if (cpu.mhz_max)
            out.push(win.spec(I18n.t("Frequenza"), `${Math.round(cpu.mhz_min ?? 0)} – ${Math.round(cpu.mhz_max)} MHz`));
        for (const level of ["L1d", "L1i", "L2", "L3"])
            if ((cpu.cache ?? ({}))[level])
                out.push(win.spec(I18n.t("Cache %1").arg(level), cpu.cache[level]));
        out.push(win.spec(I18n.t("Virtualizzazione"), cpu.virtualization));
        // Il governor dice se la macchina sta risparmiando o correndo: e' la
        // sola voce di questa pagina che cambia da un momento all'altro.
        out.push(win.spec(I18n.t("Gestione frequenza"), [cpu.governor, cpu.frequency_driver].filter(t => t).join(" · ")));

        const displays = Hardware.displays ?? [];
        if (displays.length > 0) {
            out.push(win.section(I18n.t("Uscite video")));
            for (const output of displays)
                out.push(win.device(output.connector, output.status === "connected" ? I18n.t("collegato") : I18n.t("libero"), output.enabled ? I18n.t("in uso") : "", output.status === "connected" ? "good" : ""));
        }

        return out;
    }

    function memoryRows(): var {
        const mem = Hardware.memory ?? ({});
        const out = [];

        out.push(win.section(I18n.t("Memoria")));
        out.push(win.spec(I18n.t("Totale"), Hardware.bytes(mem.total_bytes)));
        out.push(win.spec("Swap", Hardware.bytes(mem.swap_total_bytes)));
        if (mem.slots_total)
            out.push(win.spec(I18n.t("Slot"), I18n.t("%1 occupati su %2").arg(mem.slots_used ?? 0).arg(mem.slots_total)));

        const modules = mem.modules ?? [];
        if (modules.length > 0) {
            out.push(win.section(I18n.t("Banchi")));
            for (const bank of modules) {
                const parts = [bank.type, Hardware.bytes(bank.size_bytes)];
                if (bank.speed_mts)
                    parts.push(`${bank.speed_mts} MT/s`);
                // Un banco da 3600 che gira a 2133 vuol dire XMP spento: e' la
                // cosa piu' utile che questa pagina possa dire, e si vede solo
                // mettendo le due frequenze una accanto all'altra.
                if (bank.rated_mts && bank.speed_mts && bank.rated_mts !== bank.speed_mts)
                    parts.push(I18n.t("su %1 possibili").arg(`${bank.rated_mts} MT/s`));
                out.push(win.device(bank.slot || I18n.t("banco"), [bank.manufacturer, bank.part].filter(t => t).join(" ") || "—", parts.filter(t => t).join(" · "), bank.rated_mts && bank.speed_mts && bank.rated_mts > bank.speed_mts ? "warn" : ""));
            }
        }

        return out;
    }

    function graphicsRows(): var {
        const out = [];
        out.push(win.section(I18n.t("Schede grafiche")));
        for (const card of Hardware.graphics ?? []) {
            const link = card.link_width ? `PCIe ×${card.link_width}` : "";
            out.push(win.device(win.nameOf(card), [card.vendor, card.slot].filter(t => t).join(" · "), [win.driverText(card), link].filter(t => t).join(" · "), card.driver ? "" : "warn"));
        }
        if ((Hardware.graphics ?? []).length === 0)
            out.push(win.spec(I18n.t("Schede grafiche"), I18n.t("nessuna scheda dedicata")));
        return out;
    }

    function audioRows(): var {
        const audio = Hardware.audio ?? ({});
        const out = [];

        out.push(win.section(I18n.t("Audio")));
        out.push(win.spec(I18n.t("Server audio"), audio.server));

        const cards = audio.cards ?? [];
        if (cards.length > 0) {
            out.push(win.section(I18n.tn(cards.length, "Scheda audio", "Schede audio (%1)")));
            for (const card of cards)
                // Il driver ALSA ("USB-Audio") e il modulo del kernel
                // ("snd_usb_audio") sono due nomi della stessa cosa: si mostrano
                // entrambi perche' il primo si legge e il secondo si cerca.
                out.push(win.device(card.name, [card.bus === "usb" ? "USB" : "PCI", card.detail].filter(t => t).join(" · "), [card.driver, card.module].filter(t => t).join(" · "), "good"));
        }

        const controllers = audio.controllers ?? [];
        if (controllers.length > 0) {
            out.push(win.section(I18n.t("Controller sul bus")));
            for (const chip of controllers)
                out.push(win.device(win.nameOf(chip), [chip.vendor, chip.slot].filter(t => t).join(" · "), chip.driver || I18n.t("nessun driver"), chip.driver ? "" : "warn"));
        }

        return out;
    }

    function networkRows(): var {
        const out = [];
        out.push(win.section(I18n.t("Schede di rete")));
        for (const card of Hardware.network ?? []) {
            const speed = card.speed_mbit ? (card.speed_mbit >= 1000 ? `${card.speed_mbit / 1000} Gb/s` : `${card.speed_mbit} Mb/s`) : "";
            const state = card.carrier ? [I18n.t("collegata"), speed].filter(t => t).join(" ") : I18n.t("scollegata");
            out.push(win.device(card.model || card.name, [card.name, card.vendor, card.mac].filter(t => t).join(" · "), [card.driver, state].filter(t => t).join(" · "), card.carrier ? "good" : ""));
        }
        // Le interfacce virtuali (i bridge di Docker, e ce ne sono a decine)
        // non compaiono: hardware.py tiene solo quelle con un dispositivo
        // dietro, e questa pagina parla di hardware.
        if ((Hardware.network ?? []).length === 0)
            out.push(win.spec(I18n.t("Schede di rete"), I18n.t("nessuna scheda fisica")));
        return out;
    }

    function storageRows(): var {
        const out = [];
        out.push(win.section(I18n.t("Dischi")));
        for (const disk of Hardware.storage ?? []) {
            const kind = disk.rotational ? I18n.t("meccanico") : "SSD";
            out.push(win.device(disk.model || disk.name, [disk.name, disk.transport.toUpperCase(), kind, disk.firmware ? "fw " + disk.firmware : ""].filter(t => t).join(" · "), Hardware.bytes(disk.size_bytes), ""));
        }
        // La salute di questi dischi sta nel pannello Dischi della dashboard:
        // qui c'e' il pezzo di ferro, non come sta.
        return out;
    }

    function usbRows(): var {
        const out = [];
        const devices = (Hardware.usb ?? []).filter(d => !d.root_hub);

        out.push(win.section(I18n.tn(devices.length, "Dispositivo USB", "Dispositivi USB (%1)")));
        for (const item of devices) {
            const name = [item.vendor, item.product].filter(t => t).join(" ") || `${item.vendor_id}:${item.product_id}`;
            const where = I18n.t("bus %1 · porta %2").arg(item.bus ?? "?").arg(item.path);
            const what = item.hub ? I18n.t("hub") : (item.classes ?? []).join(", ");
            out.push(win.device(name, [where, what].filter(t => t).join(" · "), [(item.drivers ?? []).join(", "), Hardware.usbSpeed(item.speed_mbit)].filter(t => t).join(" · "), item.hub ? "" : "good"));
        }
        return out;
    }

    function pciRows(): var {
        const all = Hardware.pci ?? [];
        // Ponti e host bridge sono meta' dell'elenco e non sono niente che si
        // possa avere o non avere: restano fuori finche' non li si cerca.
        const shown = all.filter(d => !d.internal);
        const out = [];

        out.push(win.section(I18n.t("Schede e controller PCI")));
        for (const card of shown)
            out.push(win.device(win.nameOf(card), [card.slot, card.class, card.vendor].filter(t => t).join(" · "), win.driverText(card), card.driver ? "" : "warn"));

        if (all.length > shown.length)
            out.push(win.spec(I18n.t("Non elencati"), I18n.t("%1 ponti e dispositivi interni del chipset").arg(all.length - shown.length)));

        return out;
    }

    // Senza lspci i nomi non ci sono e restano gli identificativi numerici:
    // "10de:2504" non si legge, ma si incolla in un motore di ricerca e si
    // riconosce nell'output di qualsiasi altro strumento. Meglio dello slot da
    // solo, che non dice niente di cosa ci sia dentro.
    function nameOf(card: var): string {
        if (card.device)
            return card.device;
        if (card.vendor_id && card.device_id)
            return `${card.vendor_id}:${card.device_id}`;
        return card.slot;
    }

    // Un dispositivo senza driver legato non e' per forza rotto: puo' essere
    // che il modulo esista e nessuno l'abbia caricato. Dirlo cambia la cosa da
    // "non funziona" a "manca questo".
    function driverText(card: var): string {
        if (card.driver)
            return I18n.t("driver %1").arg(card.driver);
        const modules = card.modules ?? [];
        if (modules.length > 0)
            return I18n.t("nessun driver caricato (esiste %1)").arg(modules.join(", "));
        return I18n.t("nessun driver");
    }

    // ------------------------------------------------------------- interfaccia

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 10

        // ------------------------------------------------------ intestazione
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: "#c9d1d9"
                    font.pixelSize: 13
                    font.bold: true
                    text: (Hardware.board ?? ({})).model || I18n.t("Hardware")
                }

                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: "#6e7681"
                    font.pixelSize: 10
                    text: [Hardware.trimCpu((Hardware.cpu ?? ({})).model), Hardware.bytes((Hardware.memory ?? ({})).total_bytes)].filter(t => t && t !== "—").join(" · ")
                }
            }

            Text {
                visible: Hardware.loading
                color: "#6e7681"
                font.pixelSize: 10
                text: I18n.t("lettura…")
            }

            Rectangle {
                implicitWidth: 26
                implicitHeight: 26
                radius: 6
                color: reloadArea.containsMouse ? "#21262d" : "transparent"
                border.width: 1
                border.color: "#30363d"

                Text {
                    anchors.centerIn: parent
                    color: "#8b949e"
                    font.pixelSize: 13
                    text: "⟳"
                }

                MouseArea {
                    id: reloadArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Hardware.refresh()
                }
            }
        }

        // --------------------------------------------------------- categorie
        Flow {
            Layout.fillWidth: true
            spacing: 6

            Repeater {
                model: win.categories

                Rectangle {
                    required property var modelData

                    readonly property bool current: win.category === modelData.id

                    implicitWidth: label.implicitWidth + 20
                    implicitHeight: 26
                    radius: 6
                    color: current ? "#21262d" : "transparent"
                    border.width: 1
                    border.color: current ? "#58a6ff" : "#30363d"

                    Text {
                        id: label

                        anchors.centerIn: parent
                        color: parent.current ? "#58a6ff" : "#8b949e"
                        font.pixelSize: 11
                        text: I18n.t(parent.modelData.label)
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.category = parent.modelData.id
                    }
                }
            }
        }

        // ----------------------------------------------------------- ricerca
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 32
            radius: 6
            color: "#0d1117"
            border.width: 1
            border.color: search.activeFocus ? "#58a6ff" : "#30363d"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 8
                spacing: 6

                Text {
                    color: "#6e7681"
                    font.pixelSize: 12
                    text: "⌕"
                }

                TextInput {
                    id: search

                    Layout.fillWidth: true
                    clip: true
                    color: "#c9d1d9"
                    font.pixelSize: 12
                    selectionColor: "#1f6feb"
                    selectedTextColor: "#ffffff"
                    focus: true
                    onTextChanged: win.query = text
                    Keys.onEscapePressed: text = ""

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: search.text === ""
                        color: "#484f58"
                        font.pixelSize: 12
                        text: I18n.t("cerca un dispositivo o un driver…")
                    }
                }

                Text {
                    visible: search.text !== ""
                    color: "#6e7681"
                    font.pixelSize: 12
                    text: "✕"

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: search.text = ""
                    }
                }
            }
        }

        // ------------------------------------------------------------ elenco
        ListView {
            id: list

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: win.rows
            spacing: 1
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                id: row

                required property var modelData

                width: list.width
                implicitHeight: content.implicitHeight + (row.modelData.kind === "section" ? 14 : 10)

                Rectangle {
                    anchors.fill: parent
                    anchors.rightMargin: 8
                    visible: row.modelData.kind === "device"
                    radius: 6
                    color: hover.containsMouse ? "#161b22" : "transparent"
                }

                MouseArea {
                    id: hover

                    anchors.fill: parent
                    hoverEnabled: true
                }

                ColumnLayout {
                    id: content

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    // --- intestazione di gruppo
                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        visible: row.modelData.kind === "section"
                        color: "#484f58"
                        font.pixelSize: 10
                        font.bold: true
                        text: row.modelData.kind === "section" ? row.modelData.label.toUpperCase() : ""
                    }

                    // --- voce con due valori
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 4
                        visible: row.modelData.kind === "spec"
                        spacing: 10

                        Text {
                            Layout.preferredWidth: 150
                            elide: Text.ElideRight
                            color: "#6e7681"
                            font.pixelSize: 11
                            text: row.modelData.kind === "spec" ? row.modelData.label : ""
                        }

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            color: "#c9d1d9"
                            font.pixelSize: 11
                            text: row.modelData.kind === "spec" ? row.modelData.value : ""
                        }
                    }

                    // --- dispositivo
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 4
                        visible: row.modelData.kind === "device"
                        spacing: 8

                        // Il pallino ripete quello che dice il colore della
                        // targhetta, ma si vede anche di sfuggita: verde vuol
                        // dire acceso e guidato, giallo che manca il driver.
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            implicitWidth: 6
                            implicitHeight: 6
                            radius: 3
                            color: row.modelData.tone === "good" ? "#3fb950" : (row.modelData.tone === "warn" ? "#d29922" : "#30363d")
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1

                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                color: "#c9d1d9"
                                font.pixelSize: 11
                                text: row.modelData.kind === "device" ? row.modelData.title : ""
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: text !== ""
                                elide: Text.ElideRight
                                color: "#6e7681"
                                font.pixelSize: 10
                                text: row.modelData.kind === "device" ? (row.modelData.subtitle ?? "") : ""
                            }
                        }

                        Text {
                            Layout.maximumWidth: 240
                            visible: text !== ""
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                            color: row.modelData.tone === "warn" ? "#d29922" : "#8b949e"
                            font.pixelSize: 10
                            text: row.modelData.kind === "device" ? (row.modelData.badge ?? "") : ""
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
                visible: list.count === 0 && !Hardware.loading
                color: "#484f58"
                font.pixelSize: 12
                text: win.query === "" ? I18n.t("niente da mostrare") : I18n.t("nessun risultato per \"%1\"").arg(win.query)
            }
        }

        // ------------------------------------------------------------ footer
        Text {
            Layout.fillWidth: true
            visible: Hardware.lastError !== ""
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: "#f85149"
            font.pixelSize: 10
            text: Hardware.lastError
        }

        // La nota dei banchi di RAM compare solo quando manca il permesso di
        // leggere la tabella DMI, e porta con se' il comando che lo concede.
        Text {
            Layout.fillWidth: true
            visible: win.category === "memoria" && ((Hardware.memory ?? ({})).detail === "denied")
            wrapMode: Text.Wrap
            color: "#484f58"
            font.pixelSize: 9
            text: (Hardware.memory ?? ({})).note ?? ""
        }
    }
}
