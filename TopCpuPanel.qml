import QtQuick
import QtQuick.Layouts

ColumnLayout {
    spacing: 8

    ProcList {
        title: "TOP CPU"
        accent: "#3fb950"
        emptyText: I18n.t("nessun processo attivo")
        entries: SystemStats.topCpu.map(a => ({
                    name: a.name,
                    value: a.pct,
                    text: `${a.pct.toFixed(1)}%`
                }))
    }
}
