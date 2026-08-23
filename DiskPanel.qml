import QtQuick
import QtQuick.Layouts

// I dischi scelti nelle opzioni: per ognuno l'anello dello spazio, i numeri, e
// l'andamento di lettura e scrittura.
ColumnLayout {
    id: root

    // Solo i montati fra quelli scelti: un disco staccato non deve lasciare una
    // riga vuota, ne' sparire dalle preferenze — quando torna, ricompare.
    readonly property var chosen: SystemStats.disks.filter(d => Settings.disks.includes(d.name))

    spacing: 8

    Text {
        color: "#8b949e"
        font.pixelSize: 10
        font.letterSpacing: 1
        text: I18n.t("DISCHI")
    }

    Text {
        Layout.fillWidth: true
        visible: root.chosen.length === 0
        wrapMode: Text.Wrap
        color: "#484f58"
        font.pixelSize: 10
        text: I18n.t("nessun disco scelto (aggiungili dalle opzioni)")
    }

    Repeater {
        model: root.chosen

        ColumnLayout {
            id: disk

            required property var modelData

            readonly property var history: SystemStats.diskHistory[disk.modelData.name] ?? ({
                    read: [],
                    write: []
                })
            // fondoscala comune alle due serie, cosi' lettura e scrittura
            // restano confrontabili fra loro invece di riempire ognuna il
            // proprio grafico
            readonly property real scale: Math.max(1024 * 1024, ...disk.history.read, ...disk.history.write)
            readonly property bool active: disk.modelData.read > 0 || disk.modelData.write > 0

            readonly property var smart: disk.modelData.smart ?? ({})
            // la temperatura arriva dai sensori e non dallo SMART: quella si
            // legge senza privilegi, e c'e' anche quando il resto manca
            readonly property var probe: SystemStats.diskTemp(disk.modelData.name)

            // Un disco che sta morendo lo dice in piu' modi, e basta uno.
            readonly property bool ailing: disk.smart.passed === false || (disk.smart.realloc ?? 0) > 0 || (disk.smart.pending ?? 0) > 0 || (disk.smart.used ?? 0) >= 90

            // Quanto gli resta da vivere, per quel che se ne sa: senza i
            // privilegi per lo SMART resta la sola temperatura, che e' poco ma
            // e' vero — meglio di una riga inventata.
            readonly property string condition: {
                const s = disk.smart;
                const parts = [];
                if (s.used !== undefined && s.used !== null)
                    parts.push(I18n.t("usura %1%").arg(s.used));
                if (s.realloc > 0)
                    parts.push(I18n.t("%1 settori riallocati").arg(s.realloc));
                if (s.pending > 0)
                    parts.push(I18n.t("%1 settori in attesa").arg(s.pending));
                if (s.written > 0)
                    parts.push(I18n.t("%1 scritti").arg(SystemStats.formatBytes(s.written, false)));
                // Le ore di un disco si contano a decine di migliaia: darle
                // in giorni ("1717 g 17 h") sarebbe esatto e illeggibile.
                if (s.hours > 0)
                    parts.push(s.hours >= 8760 ? I18n.t("%1 anni acceso").arg((s.hours / 8760).toFixed(1)) : I18n.t("%1 h acceso").arg(s.hours));
                if (s.passed === false)
                    parts.unshift(I18n.t("SMART fallito"));
                if (disk.probe)
                    parts.push(`${SystemStats.tempOf(disk.probe).toFixed(0)} °C`);
                return parts.join(" · ");
            }

            Layout.fillWidth: true
            Layout.topMargin: 2
            spacing: 4

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                DiskGauge {
                    // -1 = nessun filesystem montato: la capacita' si sa, quanto
                    // sia pieno no, e disegnare uno zero direbbe "vuoto"
                    percent: disk.modelData.pct
                    unknown: disk.modelData.pct < 0
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 5

                        // il vecchio LED di attivita' del case: acceso quando il
                        // disco sta davvero leggendo o scrivendo
                        Rectangle {
                            implicitWidth: 6
                            implicitHeight: 6
                            radius: 3
                            color: disk.active ? "#e3b341" : "#21262d"

                            Behavior on color {
                                ColorAnimation {
                                    duration: 200
                                }
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            color: "#c9d1d9"
                            font.pixelSize: 12
                            text: disk.modelData.model.length > 0 ? disk.modelData.model : disk.modelData.name
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        color: "#6e7681"
                        font.pixelSize: 9
                        text: `${disk.modelData.name} · ${SystemStats.formatBytes(disk.modelData.total, false)} · ${disk.modelData.rotational ? I18n.t("disco a piatti") : "SSD"}`
                    }

                    Text {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        color: "#8b949e"
                        font.pixelSize: 10
                        text: disk.modelData.pct < 0 ? I18n.t("nessun filesystem montato") : I18n.t("%1 di %2 · %3 liberi").arg(SystemStats.formatBytes(disk.modelData.used, false)).arg(SystemStats.formatBytes(disk.modelData.formatted, false)).arg(SystemStats.formatBytes(disk.modelData.free, false))
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: disk.modelData.mounts.length > 0
                        elide: Text.ElideRight
                        color: "#484f58"
                        font.pixelSize: 9
                        font.family: "monospace"
                        text: disk.modelData.mounts.join("  ")
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: disk.condition.length > 0
                        elide: Text.ElideRight
                        color: disk.ailing ? "#f85149" : "#6e7681"
                        font.pixelSize: 9
                        text: disk.condition
                    }
                }
            }

            Sparkline {
                Layout.fillWidth: true
                implicitHeight: 34
                maxValue: disk.scale
                values: disk.history.read
                lineColor: Settings.colorFor("diskRead", "#58a6ff")
                values2: disk.history.write
                lineColor2: Settings.colorFor("diskWrite", "#db6d28")
                series: [
                    {
                        id: "diskRead",
                        label: I18n.t("Lettura"),
                        fallback: "#58a6ff"
                    },
                    {
                        id: "diskWrite",
                        label: I18n.t("Scrittura"),
                        fallback: "#db6d28"
                    }
                ]
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    color: Settings.colorFor("diskRead", "#58a6ff")
                    font.pixelSize: 9
                    text: `↓ ${SystemStats.formatBytes(disk.modelData.read, true)}`
                }

                Text {
                    Layout.fillWidth: true
                    color: Settings.colorFor("diskWrite", "#db6d28")
                    font.pixelSize: 9
                    text: `↑ ${SystemStats.formatBytes(disk.modelData.write, true)}`
                }

                Text {
                    color: "#484f58"
                    font.pixelSize: 9
                    text: I18n.t("picco %1").arg(SystemStats.formatBytes(disk.scale, true))
                }
            }
        }
    }

    // Lo SMART vuole i privilegi di root. Se non ci sono lo si dice una volta
    // per tutto il pannello, col comando da lanciare: ripeterlo su ogni disco
    // sarebbe sei volte la stessa notizia, e i dischi restano leggibili lo
    // stesso (spazio, traffico e temperatura non chiedono permessi).
    Text {
        Layout.fillWidth: true
        visible: root.chosen.length > 0 && SystemStats.health.smart === "denied"
        wrapMode: Text.Wrap
        color: "#484f58"
        font.pixelSize: 9
        text: I18n.t("salute dei dischi non leggibile senza privilegi: sudo install -m 0440 -o root -g root scripts/quickshell-smart.sudoers /etc/sudoers.d/quickshell-smart")
    }
}
