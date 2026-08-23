import QtQuick
import QtQuick.Layouts

ColumnLayout {
    spacing: 8

    ProcList {
        title: "TOP GPU"
        accent: "#a371f7"
        emptyText: I18n.t("nessun processo sulla GPU")
        // A GPU ferma tutti i processi sono a 0% di SM: in quel caso la barra
        // segue la VRAM occupata, che e' l'unica cosa che li distingue.
        entries: {
            const list = SystemStats.topGpu;
            const busy = list.some(a => a.sm > 0);
            return list.map(a => ({
                        name: a.name,
                        value: busy ? a.sm : a.mem,
                        text: `${a.sm}%`,
                        sub: SystemStats.formatBytes(a.mem, false)
                    }));
        }
    }
}
