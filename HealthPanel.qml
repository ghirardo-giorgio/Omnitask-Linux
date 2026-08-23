import QtQuick
import QtQuick.Layouts

// Le cose che si rompono in silenzio.
//
// Nessuna di queste voci ha un grafico, perche' nessuna e' una quantita' che
// cresce e cala: o va bene, o e' successo qualcosa. Le righe ci sono sempre
// tutte, anche quando sono a posto — un pannello che cambia altezza quando
// compare un problema farebbe saltare tutta la colonna proprio nel momento in
// cui si sta guardando qualcos'altro.
ColumnLayout {
    id: root

    readonly property var health: SystemStats.health
    // finche' il giro lento non ha finito il primo passaggio meta' dei campi
    // non c'e': si dice che si sta guardando, invece di mostrare degli zeri
    readonly property bool ready: root.health.kernel !== undefined

    readonly property var rows: {
        const h = root.health;
        const kernel = h.kernel ?? ({});
        const updates = h.updates ?? ({});
        const units = h.units ?? ({});
        const net = h.net ?? ({});
        const errors = (net.rxErrors ?? 0) + (net.txErrors ?? 0);
        const dropped = (net.rxDropped ?? 0) + (net.txDropped ?? 0);
        const packages = (updates.dnf ?? 0) + (updates.flatpak ?? 0);
        const failed = (units.system ?? 0) + (units.user ?? 0);
        const oom = h.oomKills ?? 0;

        return [
            {
                label: I18n.t("Acceso da"),
                value: SystemStats.formatDuration(h.uptime ?? 0),
                note: "",
                level: "info"
            },
            {
                label: I18n.t("Kernel"),
                value: kernel.rebootPending ? I18n.t("riavvio richiesto") : (kernel.running ?? "—"),
                // il numero di versione serve solo quando c'e' una decisione da
                // prendere: quale kernel si prenderebbe riavviando adesso
                note: kernel.rebootPending ? I18n.t("in uso %1, installato %2").arg(kernel.running).arg(kernel.latest) : "",
                level: kernel.rebootPending ? "warn" : "ok"
            },
            {
                label: I18n.t("Servizi falliti"),
                value: failed > 0 ? String(failed) : I18n.t("nessuno"),
                note: failed > 0 ? (units.names ?? []).join(", ") : "",
                level: failed > 0 ? "bad" : "ok"
            },
            {
                label: I18n.t("Memoria esaurita"),
                // il kernel che uccide un processo per fare spazio non lascia
                // altra traccia visibile: senza questa riga si scopre solo
                // notando che un programma non c'e' piu'
                value: oom > 0 ? I18n.tn(oom, "1 processo ucciso", "%1 processi uccisi") : I18n.t("mai"),
                note: oom > 0 && (root.health.oomSinceStart ?? 0) > 0 ? I18n.t("%1 da quando la dashboard e' aperta").arg(root.health.oomSinceStart) : "",
                level: oom > 0 ? "bad" : "ok"
            },
            {
                label: I18n.t("Pacchetti persi"),
                value: I18n.t("%1 errori, %2 scartati").arg(errors).arg(dropped),
                note: "",
                // qualche pacchetto scartato lo fa qualunque scheda: e' il
                // conteggio degli errori veri, o una valanga di scarti, a
                // voler dire che c'e' un cavo o un driver che non va
                level: errors > 0 || dropped > 100 ? "warn" : "ok"
            }
        ];
    }

    spacing: 6

    Text {
        color: "#8b949e"
        font.pixelSize: 10
        font.letterSpacing: 1
        text: I18n.t("STATO SISTEMA")
    }

    // --- aggiornamenti ---
    // Fuori dall'elenco generico perche' e' l'unica voce su cui si puo' agire:
    // due righe separate, sistema e flatpak, perche' sono operazioni con rischi
    // diversi e se una fallisce si deve vedere quale.
    ColumnLayout {
        id: updates

        // non "data": e' la proprieta' predefinita di ogni Item, dove QML mette
        // i figli, ed e' di sola lettura
        readonly property var info: root.health.updates ?? ({})
        readonly property int packages: updates.info.dnf ?? 0
        readonly property int flatpaks: updates.info.flatpak ?? 0

        Layout.fillWidth: true
        Layout.topMargin: 2
        spacing: 2

        Repeater {
            model: [
                {
                    kind: "system",
                    label: I18n.t("Aggiornamenti"),
                    count: updates.packages,
                    ready: Updates.canUpdateSystem
                },
                {
                    kind: "flatpak",
                    label: I18n.t("Flatpak"),
                    count: updates.flatpaks,
                    ready: true
                }
            ]

            RowLayout {
                id: line

                required property var modelData

                readonly property bool running: Updates.busy === line.modelData.kind
                readonly property bool actionable: line.modelData.count > 0 && line.modelData.ready && Updates.busy.length === 0

                Layout.fillWidth: true
                spacing: 8

                Text {
                    color: "#8b949e"
                    font.pixelSize: 11
                    text: line.modelData.label
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    color: line.running ? "#58a6ff" : (line.modelData.count > 0 ? "#d29922" : "#3fb950")
                    font.pixelSize: 11
                    text: {
                        if (line.running)
                            return Updates.progress >= 0 ? `${Updates.phase} ${Updates.progress}%` : (Updates.phase.length ? Updates.phase : I18n.t("in corso…"));
                        if (!root.ready)
                            return "…";
                        return line.modelData.count > 0 ? String(line.modelData.count) : I18n.t("nessuno");
                    }
                }

                // Il pulsante compare solo quando c'e' qualcosa da fare: uno
                // spento a fianco di "nessuno" sarebbe rumore.
                Rectangle {
                    visible: line.actionable
                    implicitWidth: 62
                    implicitHeight: 20
                    radius: 5
                    color: goHover.hovered ? "#1f6feb" : "transparent"
                    border.width: 1
                    border.color: goHover.hovered ? "#58a6ff" : "#30363d"

                    HoverHandler {
                        id: goHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    Text {
                        anchors.centerIn: parent
                        color: goHover.hovered ? "#ffffff" : "#8b949e"
                        font.pixelSize: 10
                        text: line.modelData.kind === updates.confirming ? I18n.t("confermi?") : I18n.t("aggiorna")
                    }

                    TapHandler {
                        onTapped: {
                            // Due passaggi per il sistema: sostituire pacchetti
                            // sotto un desktop in funzione non e' una cosa da
                            // far partire con un clic distratto. Il flatpak non
                            // puo' rompere il sistema e parte subito.
                            if (line.modelData.kind === "flatpak") {
                                Updates.updateFlatpak();
                            } else if (updates.confirming === "system") {
                                updates.confirming = "";
                                Updates.updateSystem();
                            } else {
                                updates.confirming = "system";
                                confirmTimeout.restart();
                            }
                        }
                    }
                }
            }
        }

        property string confirming: ""

        // La conferma non resta appesa: se non si clicca, dopo qualche secondo
        // il pulsante torna com'era.
        Timer {
            id: confirmTimeout

            interval: 4000
            onTriggered: updates.confirming = ""
        }

        Text {
            Layout.fillWidth: true
            visible: Updates.message.length > 0
            horizontalAlignment: Text.AlignRight
            wrapMode: Text.Wrap
            color: "#6e7681"
            font.pixelSize: 9
            text: Updates.message
        }

        Text {
            Layout.fillWidth: true
            visible: updates.packages > 0 && !Updates.canUpdateSystem
            horizontalAlignment: Text.AlignRight
            wrapMode: Text.Wrap
            color: "#484f58"
            font.pixelSize: 9
            text: I18n.t("installa PackageKit per aggiornare da qui")
        }
    }

    Repeater {
        model: root.rows

        ColumnLayout {
            id: row

            required property var modelData

            readonly property color tone: {
                if (!root.ready)
                    return "#484f58";
                if (row.modelData.level === "bad")
                    return "#f85149";
                if (row.modelData.level === "warn")
                    return "#d29922";
                return row.modelData.level === "ok" ? "#3fb950" : "#c9d1d9";
            }

            Layout.fillWidth: true
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    color: "#8b949e"
                    font.pixelSize: 11
                    text: row.modelData.label
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    color: row.tone
                    font.pixelSize: 11
                    text: root.ready || row.modelData.label === I18n.t("Acceso da") ? row.modelData.value : "…"
                }
            }

            Text {
                Layout.fillWidth: true
                visible: row.modelData.note.length > 0
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
                color: "#484f58"
                font.pixelSize: 9
                text: row.modelData.note
            }
        }
    }
}
