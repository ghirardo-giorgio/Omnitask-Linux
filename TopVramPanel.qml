import QtQuick
import QtQuick.Layouts

ColumnLayout {
    spacing: 8

    ProcList {
        title: "TOP VRAM"
        accent: "#a371f7"
        emptyText: I18n.t("nessun processo sulla GPU")
        entries: SystemStats.topVram.map(a => ({
                    name: a.name,
                    value: a.mem,
                    text: SystemStats.formatBytes(a.mem, false)
                }))
    }
}
