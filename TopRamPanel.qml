import QtQuick
import QtQuick.Layouts

ColumnLayout {
    spacing: 8

    ProcList {
        title: "TOP RAM"
        accent: "#58a6ff"
        emptyText: I18n.t("in calcolo…")
        entries: SystemStats.topRam.map(a => ({
                    name: a.name,
                    value: a.bytes,
                    text: SystemStats.formatBytes(a.bytes, false)
                }))
    }
}
