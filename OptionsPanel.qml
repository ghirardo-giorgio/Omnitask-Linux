import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Composizione della dashboard: quali pannelli, dove, in che ordine e con che
// parametri. Ogni modifica va subito su disco (vedi Settings) e la dashboard la
// riflette all'istante: non c'e' nessun "applica" da premere.
//
// L'ordine si cambia trascinando la maniglia a sinistra della riga. Il
// trascinamento resta dentro il proprio gruppo: portare un pannello da una
// colonna all'altra e' un'altra cosa, e si dice coi pulsanti S/D.
Rectangle {
    id: win

    property bool reordering: false
    // Stato persistente dell'espansione dei dischi.
    // Non viene perso quando SystemStats aggiorna SystemStats.disks
    // e il Repeater ricrea i delegate.
    property var expandedDisks: ({})
    readonly property int rowHeight: 36
    readonly property int entityRowHeight: 38

    implicitWidth: 620
    implicitHeight: 700
    color: "#0d1117"

    function addEntity(entityId: string) {
        Settings.addEntity(entityId);
        entitySearch.text = "";
    }
    function isDiskExpanded(name: string): bool {
        return win.expandedDisks[name] === true;
    }

    function setDiskExpanded(name: string, expanded: bool) {
        const state = Object.assign({}, win.expandedDisks);

        if (expanded)
            state[name] = true;
        else
            delete state[name];

        win.expandedDisks = state;
    }

    function toggleDiskExpanded(name: string) {
        win.setDiskExpanded(
            name,
            !win.isDiskExpanded(name)
        );
    }
    readonly property var entityMatches: {
        const query = entitySearch.text.trim().toLowerCase();

        if (query.length < 2)
            return [];

        const out = [];

        for (const id in HomeAssistant.states) {
            if (Settings.haEntities.includes(id))
                continue;

            const name = HomeAssistant.friendlyName(id);

            if (id.toLowerCase().includes(query)
                    || name.toLowerCase().includes(query)) {
                out.push({
                    id: id,
                    name: name
                });
            }

            if (out.length >= 8)
                break;
        }

        return out;
    }

    // ================================================== mount dei dischi
    //
    // Ogni partizione viene montata singolarmente. La coda serve a evitare
    // più richieste udisks/polkit contemporaneamente.
    property var mountQueue: []

    function mountPartition(path: string) {
        if (!path || path.length === 0)
            return;

        if (win.mountQueue.includes(path))
            return;

        win.mountQueue.push(path);

        if (!mountProc.running)
            win.runNextMount();
    }

    function runNextMount() {
        if (win.mountQueue.length === 0)
            return;

        const path = win.mountQueue.shift();

        mountProc.command = [
            "udisksctl",
            "mount",
            "-b",
            path
        ];

        mountProc.running = true;
    }

    function unmountPartition(path: string) {
        if (!path || path.length === 0)
            return;

        if (unmountProc.running)
            return;

        unmountProc.command = [
            "udisksctl",
            "unmount",
            "-b",
            path
        ];

        unmountProc.running = true;
    }

    Process {
        id: mountProc

        onExited: {
            win.runNextMount();
            SystemStats.restart();
        }
    }

    Process {
        id: unmountProc

        onExited: {
            SystemStats.restart();
        }
    }

    Flickable {
        id: scroll

        anchors.fill: parent
        anchors.margins: 12

        contentHeight: content.implicitHeight

        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: !win.reordering

        ColumnLayout {
            id: content

            // Dodici pixel in meno della pista: la barra di scorrimento sta
            // sopra il contenuto, non accanto, e senza questo spazio copre le
            // icone allineate a destra delle righe.
            width: scroll.width - 12
            spacing: 8

            // ==================================================== pannelli

            Text {
                color: "#8b949e"
                font.pixelSize: 10
                font.letterSpacing: 1
                text: I18n.t("PANNELLI")
            }

            Text {
                Layout.fillWidth: true
                Layout.bottomMargin: 2

                wrapMode: Text.Wrap
                color: "#6e7681"
                font.pixelSize: 10

                text: I18n.t(
                    "Trascina ⠿ per cambiare l'ordine dentro la colonna, S/C/D per spostare un pannello in un'altra, l'interruttore per spegnerlo. La colonna centrale compare nella dashboard solo quando ha qualcosa dentro."
                )
            }

            Repeater {
                model: [
                    {
                        key: "left",
                        title: I18n.t("COLONNA SINISTRA"),
                        draggable: true
                    },
                    {
                        key: "center",
                        title: I18n.t("COLONNA CENTRALE"),
                        draggable: true
                    },
                    {
                        key: "right",
                        title: I18n.t("COLONNA DESTRA"),
                        draggable: true
                    },
                    {
                        key: "off",
                        title: I18n.t("SPENTI"),
                        draggable: false
                    }
                ]

                ColumnLayout {
                    id: group

                    required property var modelData

                    readonly property var ids: {
                        if (group.modelData.key === "left")
                            return Settings.left;

                        if (group.modelData.key === "center")
                            return Settings.center;

                        if (group.modelData.key === "right")
                            return Settings.right;

                        return Settings.catalog
                            .map(p => p.id)
                            .filter(id => !Settings.isVisible(id));
                    }

                    property string dragId: ""
                    property real dragOffset: 0

                    readonly property int startIndex:
                        group.ids.indexOf(group.dragId)

                    readonly property int dropIndex: {
                        if (group.startIndex < 0)
                            return -1;

                        const moved =
                            group.startIndex
                            + Math.round(
                                group.dragOffset / win.rowHeight
                            );

                        return Math.max(
                            0,
                            Math.min(
                                group.ids.length - 1,
                                moved
                            )
                        );
                    }

                    function displayIndex(index: int): int {
                        if (group.startIndex < 0
                                || index === group.startIndex)
                            return index;

                        if (group.startIndex < group.dropIndex
                                && index > group.startIndex
                                && index <= group.dropIndex)
                            return index - 1;

                        if (group.startIndex > group.dropIndex
                                && index >= group.dropIndex
                                && index < group.startIndex)
                            return index + 1;

                        return index;
                    }

                    function clampOffset(offset: real): real {
                        if (group.startIndex < 0)
                            return 0;

                        const min =
                            -group.startIndex * win.rowHeight;

                        const max =
                            (group.ids.length - 1
                             - group.startIndex)
                            * win.rowHeight;

                        return Math.max(
                            min,
                            Math.min(max, offset)
                        );
                    }

                    Layout.fillWidth: true
                    Layout.topMargin: 4

                    visible: group.ids.length > 0
                    spacing: 2

                    Text {
                        color: "#484f58"
                        font.pixelSize: 9
                        font.letterSpacing: 1

                        text: group.modelData.title
                    }

                    Item {
                        Layout.fillWidth: true

                        Layout.preferredHeight:
                            group.ids.length * win.rowHeight

                        Repeater {
                            model: group.ids

                            Rectangle {
                                id: panelRow

                                required property string modelData
                                required property int index

                                readonly property string column:
                                    Settings.columnOf(
                                        panelRow.modelData
                                    )

                                readonly property bool active:
                                    panelRow.column !== ""

                                readonly property bool dragging:
                                    group.dragId
                                    === panelRow.modelData

                                width: parent.width
                                height: win.rowHeight - 2

                                y:
                                    panelRow.dragging
                                    ? group.startIndex
                                      * win.rowHeight
                                      + group.dragOffset
                                    : group.displayIndex(
                                        panelRow.index
                                      ) * win.rowHeight

                                z:
                                    panelRow.dragging ? 2 : 1

                                radius: 6

                                color:
                                    panelRow.dragging
                                    ? "#1c2331"
                                    : rowHover.hovered
                                      ? "#161b22"
                                      : "transparent"

                                border.width: 1

                                border.color:
                                    panelRow.dragging
                                    ? "#58a6ff"
                                    : panelRow.active
                                      ? "#30363d"
                                      : "transparent"

                                Behavior on y {
                                    enabled:
                                        !panelRow.dragging

                                    NumberAnimation {
                                        duration: 120
                                        easing.type:
                                            Easing.OutQuad
                                    }
                                }

                                HoverHandler {
                                    id: rowHover
                                }

                                RowLayout {
                                    anchors.fill: parent

                                    anchors.leftMargin: 6
                                    anchors.rightMargin: 8

                                    spacing: 6

                                    Text {
                                        Layout.preferredWidth: 14

                                        horizontalAlignment:
                                            Text.AlignHCenter

                                        visible:
                                            group.modelData.draggable

                                        color:
                                            panelRow.dragging
                                            ? "#58a6ff"
                                            : handleHover.hovered
                                              ? "#8b949e"
                                              : "#30363d"

                                        font.pixelSize: 12
                                        text: "⠿"

                                        HoverHandler {
                                            id: handleHover

                                            cursorShape:
                                                Qt.OpenHandCursor
                                        }

                                        DragHandler {
                                            id: panelDrag

                                            target: null

                                            xAxis.enabled: false
                                            yAxis.enabled: true

                                            grabPermissions:
                                                PointerHandler
                                                .CanTakeOverFromAnything

                                            // Prima si legge dove va a finire,
                                            // poi si spegne il trascinamento,
                                            // e solo alla fine si sposta.
                                            //
                                            // L'ordine non e' estetico. `moveTo`
                                            // riscrive la lista della colonna, il
                                            // Repeater butta via i delegate e con
                                            // essi il contesto QML di questo
                                            // handler: da li' in poi `group` non
                                            // si risolve piu' e l'assegnazione
                                            // successiva muore con un
                                            // "ReferenceError: group is not
                                            // defined", portandosi dietro anche le
                                            // righe dopo. Restavano quindi accesi
                                            // sia `dragId` — e la riga continuava a
                                            // disegnarsi dov'era il dito, col bordo
                                            // blu, sopra il gruppo seguente — sia
                                            // `win.reordering`, che tiene fermo lo
                                            // scorrimento dell'intero pannello.
                                            // Spostando la chiamata in coda non
                                            // resta piu' niente da eseguire dopo.
                                            onActiveChanged: {
                                                if (panelDrag.active) {
                                                    group.dragId =
                                                        panelRow.modelData;

                                                    group.dragOffset = 0;
                                                    win.reordering = true;
                                                    return;
                                                }

                                                const id = panelRow.modelData;
                                                const from = group.startIndex;
                                                const to = group.dropIndex;

                                                group.dragId = "";
                                                group.dragOffset = 0;
                                                win.reordering = false;

                                                if (to >= 0 && to !== from)
                                                    Settings.moveTo(id, to);
                                            }

                                            onTranslationChanged: {
                                                if (panelDrag.active) {
                                                    group.dragOffset =
                                                        group.clampOffset(
                                                            panelDrag.translation.y
                                                        );
                                                }
                                            }
                                        }
                                    }

                                    Rectangle {
                                        implicitWidth: 32
                                        implicitHeight: 18
                                        radius: 9

                                        color:
                                            panelRow.active
                                            ? "#1f6feb"
                                            : "#21262d"

                                        border.width: 1

                                        border.color:
                                            panelRow.active
                                            ? "#58a6ff"
                                            : "#30363d"

                                        Rectangle {
                                            width: 12
                                            height: 12
                                            radius: 6

                                            anchors.verticalCenter:
                                                parent.verticalCenter

                                            x:
                                                panelRow.active
                                                ? parent.width
                                                  - width
                                                  - 3
                                                : 3

                                            color:
                                                panelRow.active
                                                ? "#ffffff"
                                                : "#6e7681"

                                            Behavior on x {
                                                NumberAnimation {
                                                    duration: 120
                                                }
                                            }
                                        }

                                        MouseArea {
                                            anchors.fill: parent

                                            cursorShape:
                                                Qt.PointingHandCursor

                                            onClicked:
                                                Settings.toggle(
                                                    panelRow.modelData
                                                )
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true

                                        elide:
                                            Text.ElideRight

                                        color:
                                            panelRow.active
                                            ? "#c9d1d9"
                                            : "#6e7681"

                                        font.pixelSize: 12

                                        text:
                                            Settings.titleFor(
                                                panelRow.modelData
                                            )
                                    }

                                    Repeater {
                                        model:
                                            panelRow.active
                                            ? [
                                                {
                                                    id: "left",
                                                    label: "S"
                                                },
                                                {
                                                    id: "center",
                                                    label: "C"
                                                },
                                                {
                                                    id: "right",
                                                    label: "D"
                                                }
                                            ]
                                            : []

                                        Rectangle {
                                            id: columnButton

                                            required property var modelData

                                            readonly property bool current:
                                                panelRow.column
                                                === columnButton.modelData.id

                                            implicitWidth: 22
                                            implicitHeight: 20

                                            radius: 4

                                            color:
                                                columnButton.current
                                                ? "#21262d"
                                                : "transparent"

                                            border.width: 1

                                            border.color:
                                                columnButton.current
                                                ? "#58a6ff"
                                                : "#30363d"

                                            Text {
                                                anchors.centerIn: parent

                                                color:
                                                    columnButton.current
                                                    ? "#58a6ff"
                                                    : "#6e7681"

                                                font.pixelSize: 10

                                                text:
                                                    I18n.t(
                                                        columnButton
                                                        .modelData
                                                        .label
                                                    )
                                            }

                                            MouseArea {
                                                anchors.fill: parent

                                                cursorShape:
                                                    Qt.PointingHandCursor

                                                onClicked:
                                                    Settings.move(
                                                        panelRow.modelData,
                                                        columnButton
                                                        .modelData.id
                                                    )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ========================================= pannelli aggiunti
            //
            // Una riga sola, in coda all'elenco: chi non ha aggiunto niente
            // non ha bisogno di sapere che si puo'. Chi l'ha fatto trova qui
            // la cartella, il pulsante per rileggerla e i guasti.

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 8

                spacing: 6

                Text {
                    Layout.fillWidth: true

                    wrapMode: Text.Wrap
                    color: "#484f58"
                    font.pixelSize: 9

                    text:
                        UserPanels.entries.length === 0
                        ? I18n.t("Puoi aggiungere pannelli tuoi mettendo un .qml in panels/ — vedi il README.")
                        : I18n.tn(
                            UserPanels.usable.length,
                            "1 pannello aggiunto da panels/",
                            "%1 pannelli aggiunti da panels/"
                        )
                }

                Rectangle {
                    implicitWidth: 24
                    implicitHeight: 22
                    radius: 6

                    color: panelsRescanHover.hovered ? "#21262d" : "transparent"

                    border.width: 1
                    border.color: "#30363d"

                    HoverHandler {
                        id: panelsRescanHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    Text {
                        anchors.centerIn: parent
                        color: "#8b949e"
                        font.pixelSize: 12
                        text: UserPanels.loading ? "…" : "⟳"
                    }

                    TapHandler {
                        onTapped: UserPanels.refresh()
                    }
                }
            }

            // Un .qml non e' un file di impostazioni: e' un programma, e gira
            // coi permessi di chi apre la dashboard. Detto una volta, dove si
            // vedono, e non nascosto in fondo a un README.
            Text {
                Layout.fillWidth: true

                visible: UserPanels.entries.length > 0

                wrapMode: Text.Wrap
                color: "#484f58"
                font.pixelSize: 9

                text:
                    I18n.t(
                        "Un pannello è codice eseguibile, non una configurazione: può avviare programmi e leggere i tuoi file. Installa solo quelli di cui ti fidi."
                    )
            }

            // I file che non possono caricarsi non entrano nel catalogo, e
            // senza questa riga sparirebbero senza dire niente.
            Repeater {
                model: UserPanels.broken

                Text {
                    required property var modelData

                    Layout.fillWidth: true

                    wrapMode: Text.Wrap
                    color: "#d29922"
                    font.pixelSize: 9

                    text: modelData.title + ": " + modelData.error
                }
            }

            // Lo stesso per gli avvisi: il pannello si carica, ma senza
            // `import ".."` non vede niente della dashboard.
            Repeater {
                model: UserPanels.usable.filter(p => p.warning !== undefined)

                Text {
                    required property var modelData

                    Layout.fillWidth: true

                    wrapMode: Text.Wrap
                    color: "#d29922"
                    font.pixelSize: 9

                    text: modelData.title + ": " + modelData.warning
                }
            }

            Text {
                Layout.fillWidth: true

                visible: UserPanels.lastError !== ""

                wrapMode: Text.Wrap
                color: "#f85149"
                font.pixelSize: 9

                text: UserPanels.lastError
            }

            // ============================================= Home Assistant

            Text {
                Layout.topMargin: 10

                color: "#8b949e"
                font.pixelSize: 10
                font.letterSpacing: 1

                text: I18n.t("ENTITÀ HOME ASSISTANT")
            }

            Text {
                Layout.fillWidth: true

                visible:
                    Settings.haEntities.length > 1

                wrapMode: Text.Wrap
                color: "#6e7681"
                font.pixelSize: 10

                text:
                    I18n.t(
                        "L'ordine è quello con cui compaiono nel pannello: trascina ⠿ per cambiarlo."
                    )
            }

            Item {
                id: entityList

                property string dragId: ""
                property real dragOffset: 0

                readonly property int startIndex:
                    Settings.haEntities.indexOf(
                        entityList.dragId
                    )

                readonly property int dropIndex: {
                    if (entityList.startIndex < 0)
                        return -1;

                    const moved =
                        entityList.startIndex
                        + Math.round(
                            entityList.dragOffset
                            / win.entityRowHeight
                        );

                    return Math.max(
                        0,
                        Math.min(
                            Settings.haEntities.length - 1,
                            moved
                        )
                    );
                }

                function displayIndex(index: int): int {
                    if (entityList.startIndex < 0
                            || index === entityList.startIndex)
                        return index;

                    if (entityList.startIndex
                            < entityList.dropIndex
                            && index > entityList.startIndex
                            && index <= entityList.dropIndex)
                        return index - 1;

                    if (entityList.startIndex
                            > entityList.dropIndex
                            && index >= entityList.dropIndex
                            && index < entityList.startIndex)
                        return index + 1;

                    return index;
                }

                function clampOffset(offset: real): real {
                    if (entityList.startIndex < 0)
                        return 0;

                    const min =
                        -entityList.startIndex
                        * win.entityRowHeight;

                    const max =
                        (Settings.haEntities.length - 1
                         - entityList.startIndex)
                        * win.entityRowHeight;

                    return Math.max(
                        min,
                        Math.min(max, offset)
                    );
                }

                Layout.fillWidth: true

                Layout.preferredHeight:
                    Settings.haEntities.length
                    * win.entityRowHeight

                Repeater {
                    model: Settings.haEntities

                    Rectangle {
                        id: entityRow

                        required property string modelData
                        required property int index

                        readonly property bool dragging:
                            entityList.dragId
                            === entityRow.modelData

                        width: parent.width
                        height: win.entityRowHeight - 2

                        y:
                            entityRow.dragging
                            ? entityList.startIndex
                              * win.entityRowHeight
                              + entityList.dragOffset
                            : entityList.displayIndex(
                                entityRow.index
                              ) * win.entityRowHeight

                        z:
                            entityRow.dragging ? 2 : 1

                        radius: 6

                        color:
                            entityRow.dragging
                            ? "#1c2331"
                            : entityHover.hovered
                              ? "#161b22"
                              : "transparent"

                        border.width: 1

                        border.color:
                            entityRow.dragging
                            ? "#58a6ff"
                            : "#30363d"

                        Behavior on y {
                            enabled:
                                !entityRow.dragging

                            NumberAnimation {
                                duration: 120
                                easing.type:
                                    Easing.OutQuad
                            }
                        }

                        HoverHandler {
                            id: entityHover
                        }

                        RowLayout {
                            anchors.fill: parent

                            anchors.leftMargin: 6
                            anchors.rightMargin: 6

                            spacing: 6

                            Text {
                                Layout.preferredWidth: 14

                                horizontalAlignment:
                                    Text.AlignHCenter

                                visible:
                                    Settings.haEntities.length > 1

                                color:
                                    entityRow.dragging
                                    ? "#58a6ff"
                                    : entityHandleHover.hovered
                                      ? "#8b949e"
                                      : "#30363d"

                                font.pixelSize: 12
                                text: "⠿"

                                HoverHandler {
                                    id: entityHandleHover

                                    cursorShape:
                                        Qt.OpenHandCursor
                                }

                                DragHandler {
                                    id: entityDrag

                                    target: null

                                    xAxis.enabled: false
                                    yAxis.enabled: true

                                    grabPermissions:
                                        PointerHandler
                                        .CanTakeOverFromAnything

                                    // Stesso ordine, e per la stessa ragione,
                                    // del trascinamento dei pannelli qui sopra:
                                    // la riscrittura della lista distrugge il
                                    // delegate che ospita questo handler, quindi
                                    // deve essere l'ultima cosa che succede.
                                    onActiveChanged: {
                                        if (entityDrag.active) {
                                            entityList.dragId =
                                                entityRow.modelData;

                                            entityList.dragOffset = 0;
                                            win.reordering = true;
                                            return;
                                        }

                                        const id = entityRow.modelData;
                                        const from = entityList.startIndex;
                                        const to = entityList.dropIndex;

                                        entityList.dragId = "";
                                        entityList.dragOffset = 0;
                                        win.reordering = false;

                                        if (to >= 0 && to !== from)
                                            Settings.moveEntityTo(id, to);
                                    }

                                    onTranslationChanged: {
                                        if (entityDrag.active) {
                                            entityList.dragOffset =
                                                entityList.clampOffset(
                                                    entityDrag.translation.y
                                                );
                                        }
                                    }
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                Text {
                                    Layout.fillWidth: true

                                    elide:
                                        Text.ElideRight

                                    color: "#c9d1d9"
                                    font.pixelSize: 11

                                    text:
                                        HomeAssistant.friendlyName(
                                            entityRow.modelData
                                        )
                                }

                                Text {
                                    Layout.fillWidth: true

                                    elide:
                                        Text.ElideRight

                                    color: "#484f58"
                                    font.pixelSize: 9
                                    font.family: "monospace"

                                    text:
                                        entityRow.modelData
                                }
                            }

                            Rectangle {
                                id: chartToggle

                                readonly property bool on:
                                    Settings.chartEnabled(
                                        entityRow.modelData
                                    )

                                implicitWidth: 60
                                implicitHeight: 20
                                radius: 4

                                color:
                                    chartToggle.on
                                    ? "#12261a"
                                    : "transparent"

                                border.width: 1

                                border.color:
                                    chartToggle.on
                                    ? "#3fb950"
                                    : "#30363d"

                                Text {
                                    anchors.centerIn: parent

                                    color:
                                        chartToggle.on
                                        ? "#3fb950"
                                        : "#6e7681"

                                    font.pixelSize: 9

                                    text:
                                        chartToggle.on
                                        ? I18n.t("grafico")
                                        : I18n.t("solo dato")
                                }

                                MouseArea {
                                    anchors.fill: parent

                                    cursorShape:
                                        Qt.PointingHandCursor

                                    onClicked:
                                        Settings.toggleChart(
                                            entityRow.modelData
                                        )
                                }
                            }

                            Rectangle {
                                implicitWidth: 22
                                implicitHeight: 20
                                radius: 4

                                color:
                                    removeArea.containsMouse
                                    ? "#21262d"
                                    : "transparent"

                                Text {
                                    anchors.centerIn: parent

                                    color: "#f85149"
                                    font.pixelSize: 11

                                    text: "✕"
                                }

                                MouseArea {
                                    id: removeArea

                                    anchors.fill: parent

                                    hoverEnabled: true

                                    cursorShape:
                                        Qt.PointingHandCursor

                                    onClicked:
                                        Settings.removeEntity(
                                            entityRow.modelData
                                        )
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: 2

                implicitHeight: 30
                radius: 6

                color: "#161b22"

                border.width: 1

                border.color:
                    entitySearch.activeFocus
                    ? "#58a6ff"
                    : "#30363d"

                RowLayout {
                    anchors.fill: parent

                    anchors.leftMargin: 10
                    anchors.rightMargin: 8

                    spacing: 6

                    Text {
                        color: "#6e7681"
                        font.pixelSize: 11
                        text: "＋"
                    }

                    TextInput {
                        id: entitySearch

                        Layout.fillWidth: true

                        clip: true
                        color: "#c9d1d9"
                        font.pixelSize: 12

                        selectionColor: "#1f6feb"

                        Keys.onEscapePressed:
                            text = ""

                        Text {
                            anchors.verticalCenter:
                                parent.verticalCenter

                            visible:
                                entitySearch.text === ""

                            color: "#484f58"
                            font.pixelSize: 12

                            text:
                                HomeAssistant.online
                                ? I18n.t(
                                    "aggiungi un'entità: cerca per nome o entity_id…"
                                  )
                                : I18n.t(
                                    "Home Assistant non raggiungibile"
                                  )
                        }
                    }
                }
            }

            Repeater {
                model: win.entityMatches

                Rectangle {
                    id: matchRow

                    required property var modelData

                    Layout.fillWidth: true
                    Layout.leftMargin: 12

                    implicitHeight: 28
                    radius: 6

                    color:
                        matchArea.containsMouse
                        ? "#161b22"
                        : "transparent"

                    RowLayout {
                        anchors.fill: parent

                        anchors.leftMargin: 8
                        anchors.rightMargin: 8

                        spacing: 6

                        Text {
                            Layout.fillWidth: true

                            elide:
                                Text.ElideRight

                            color: "#c9d1d9"
                            font.pixelSize: 11

                            text:
                                matchRow.modelData.name
                        }

                        Text {
                            color: "#6e7681"
                            font.pixelSize: 10

                            text:
                                HomeAssistant.state(
                                    matchRow.modelData.id
                                )
                                + " "
                                + HomeAssistant.unit(
                                    matchRow.modelData.id
                                )
                        }
                    }

                    MouseArea {
                        id: matchArea

                        anchors.fill: parent

                        hoverEnabled: true

                        cursorShape:
                            Qt.PointingHandCursor

                        onClicked:
                            win.addEntity(
                                matchRow.modelData.id
                            )
                    }
                }
            }

            // ===================================================== lingua

            Text {
                Layout.topMargin: 10

                color: "#8b949e"
                font.pixelSize: 10
                font.letterSpacing: 1

                text: I18n.t("LINGUA")
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 4

                Repeater {
                    model: [
                        { code: "", label: "AUTO" },
                        { code: "it", label: "IT" },
                        { code: "en", label: "EN" },
                        { code: "fr", label: "FR" },
                        { code: "de", label: "DE" },
                        { code: "es", label: "ES" },
                        { code: "ja", label: "JA" }
                    ]

                    Rectangle {
                        id: langButton

                        required property var modelData

                        readonly property bool current:
                            Settings.language
                            === langButton.modelData.code

                        Layout.fillWidth: true

                        implicitHeight: 24
                        radius: 4

                        color:
                            langButton.current
                            ? "#21262d"
                            : "transparent"

                        border.width: 1

                        border.color:
                            langButton.current
                            ? "#58a6ff"
                            : "#30363d"

                        Text {
                            anchors.centerIn: parent

                            color:
                                langButton.current
                                ? "#58a6ff"
                                : "#6e7681"

                            font.pixelSize: 10

                            text:
                                langButton.modelData.label
                        }

                        MouseArea {
                            anchors.fill: parent

                            cursorShape:
                                Qt.PointingHandCursor

                            onClicked:
                                Settings.setLanguage(
                                    langButton.modelData.code
                                )
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true

                wrapMode: Text.Wrap
                color: "#6e7681"
                font.pixelSize: 10

                text:
                    I18n.t(
                        "in uso: %1"
                    ).arg(
                        I18n.lang.toUpperCase()
                    )
            }

            // ==================================================== dischi

            RowLayout {
                Layout.topMargin: 10
                Layout.fillWidth: true
                spacing: 8

                Text {
                    Layout.fillWidth: true

                    color: "#8b949e"
                    font.pixelSize: 10
                    font.letterSpacing: 1

                    text: I18n.t("DISCHI")
                }

                Rectangle {
                    implicitWidth: 24
                    implicitHeight: 20
                    radius: 4

                    color:
                        rescanHover.hovered
                        ? "#21262d"
                        : "transparent"

                    border.width: 1
                    border.color: "#30363d"

                    HoverHandler {
                        id: rescanHover

                        cursorShape:
                            Qt.PointingHandCursor
                    }

                    Text {
                        anchors.centerIn: parent

                        color: "#8b949e"
                        font.pixelSize: 12
                        text: "⟳"

                        RotationAnimation on rotation {
                            id: spin

                            running: false

                            from: 0
                            to: 360

                            duration: 600
                        }
                    }

                    TapHandler {
                        onTapped: {
                            SystemStats.restart();
                            spin.restart();
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true

                wrapMode: Text.Wrap
                color: "#6e7681"
                font.pixelSize: 10

                text:
                    I18n.t(
                        "I dischi collegati alla macchina. Espandi un disco per vedere e montare singolarmente le sue partizioni."
                    )
            }

            Repeater {
                model: SystemStats.disks

                Item {
                    id: diskItem

                    required property var modelData

                    readonly property bool on:
                        Settings.disks.includes(
                            diskItem.modelData.name
                        )

                    readonly property bool expanded:
                        win.isDiskExpanded(
                            diskItem.modelData.name
                        )
                    readonly property var partitions:
                        diskItem.modelData.partitions ?? []

                    Layout.fillWidth: true

                    Layout.preferredHeight:
                        38
                        + (
                            diskItem.expanded
                            ? diskItem.partitions.length * 34
                            : 0
                        )

                    Rectangle {
                        id: diskRow

                        width: parent.width
                        height: 38

                        radius: 6

                        color:
                            diskHover.hovered
                            ? "#161b22"
                            : "transparent"

                        border.width: 1

                        border.color:
                            diskItem.on
                            ? "#30363d"
                            : "transparent"

                        HoverHandler {
                            id: diskHover

                            cursorShape:
                                Qt.ArrowCursor
                        }

                        RowLayout {
                            anchors.fill: parent

                            anchors.leftMargin: 8
                            anchors.rightMargin: 8

                            spacing: 8

                            // Espansione disco
                            Text {
                                Layout.preferredWidth: 14

                                horizontalAlignment:
                                    Text.AlignHCenter

                                color:
                                    diskItem.partitions.length > 0
                                    ? "#8b949e"
                                    : "#30363d"

                                font.pixelSize: 11

                                text:
                                    diskItem.partitions.length > 0
                                    ? (
                                        diskItem.expanded
                                        ? "▾"
                                        : "▸"
                                      )
                                    : ""

                                MouseArea {
                                    anchors.fill: parent

                                    enabled:
                                        diskItem.partitions.length > 0

                                    cursorShape:
                                        Qt.PointingHandCursor

                                    onClicked:
                                        win.toggleDiskExpanded(
                                            diskItem.modelData.name
                                        )
                                }
                            }

                            // Toggle visualizzazione disco
                            Rectangle {
                                implicitWidth: 32
                                implicitHeight: 18
                                radius: 9

                                color:
                                    diskItem.on
                                    ? "#1f6feb"
                                    : "#21262d"

                                border.width: 1

                                border.color:
                                    diskItem.on
                                    ? "#58a6ff"
                                    : "#30363d"

                                Rectangle {
                                    width: 12
                                    height: 12
                                    radius: 6

                                    anchors.verticalCenter:
                                        parent.verticalCenter

                                    x:
                                        diskItem.on
                                        ? parent.width
                                          - width
                                          - 3
                                        : 3

                                    color:
                                        diskItem.on
                                        ? "#ffffff"
                                        : "#6e7681"

                                    Behavior on x {
                                        NumberAnimation {
                                            duration: 120
                                        }
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent

                                    cursorShape:
                                        Qt.PointingHandCursor

                                    onClicked:
                                        Settings.toggleDisk(
                                            diskItem.modelData.name
                                        )
                                }
                            }

                            // Nome e informazioni disco
                            ColumnLayout {
                                Layout.fillWidth: true

                                spacing: 0

                                Text {
                                    Layout.fillWidth: true

                                    elide:
                                        Text.ElideMiddle

                                    color:
                                        diskItem.on
                                        ? "#c9d1d9"
                                        : "#8b949e"

                                    font.pixelSize: 11

                                    text:
                                        diskItem.modelData.model.length > 0
                                        ? diskItem.modelData.model
                                        : diskItem.modelData.name
                                }

                                Text {
                                    Layout.fillWidth: true

                                    elide:
                                        Text.ElideRight

                                    color: "#484f58"

                                    font.pixelSize: 9
                                    font.family: "monospace"

                                    text:
                                        `${diskItem.modelData.name} · `
                                        + `${SystemStats.formatBytes(
                                               diskItem.modelData.total,
                                               false
                                           )} · `
                                        + `${diskItem.modelData.rotational
                                            ? I18n.t("disco a piatti")
                                            : "SSD"}`
                                }
                            }

                            // Barra utilizzo del filesystem principale,
                            // se SystemStats ne fornisce uno.
                            Rectangle {
                                implicitWidth: 54
                                implicitHeight: 6
                                radius: 3

                                visible:
                                    diskItem.modelData.pct >= 0

                                color: "#21262d"

                                Rectangle {
                                    width:
                                        parent.width
                                        * Math.min(
                                            100,
                                            diskItem.modelData.pct
                                        )
                                        / 100

                                    height: parent.height
                                    radius: 3

                                    color:
                                        diskItem.modelData.pct >= 90
                                        ? "#f85149"
                                        : diskItem.modelData.pct >= 75
                                          ? "#d29922"
                                          : "#3fb950"
                                }
                            }

                            Text {
                                Layout.minimumWidth: 84

                                visible:
                                    diskItem.modelData.pct >= 0

                                horizontalAlignment:
                                    Text.AlignRight

                                color: "#8b949e"
                                font.pixelSize: 10

                                text:
                                    `${SystemStats.formatBytes(
                                        diskItem.modelData.used,
                                        false
                                    )} / ${SystemStats.formatBytes(
                                        diskItem.modelData.formatted,
                                        false
                                    )}`
                            }
                        }
                    }

                    // ==================================================
                    // Lista delle singole partizioni
                    // ==================================================

                    Item {
                        id: partitionList

                        anchors.top:
                            diskRow.bottom

                        anchors.left:
                            parent.left

                        anchors.right:
                            parent.right

                        height:
                            diskItem.expanded
                            ? diskItem.partitions.length * 34
                            : 0

                        clip: true

                        Repeater {
                            model:
                                diskItem.partitions

                            Rectangle {
                                id: partitionRow

                                required property var modelData
                                required property int index

                                readonly property bool mounted:
                                    partitionRow.modelData.mountpoint
                                    && partitionRow.modelData.mountpoint.length > 0

                                readonly property bool mountable:
                                    partitionRow.modelData.fstype
                                    && partitionRow.modelData.fstype
                                       !== "crypto_LUKS"
                                    && partitionRow.modelData.fstype
                                       !== "swap"

                                width: parent.width
                                height: 32

                                y:
                                    partitionRow.index * 34

                                radius: 5

                                color:
                                    partitionHover.hovered
                                    ? "#161b22"
                                    : "transparent"

                                HoverHandler {
                                    id: partitionHover

                                    cursorShape:
                                        Qt.ArrowCursor
                                }

                                RowLayout {
                                    anchors.fill: parent

                                    anchors.leftMargin: 34
                                    anchors.rightMargin: 8

                                    spacing: 8

                                    Text {
                                        Layout.preferredWidth: 12

                                        color: "#484f58"
                                        font.pixelSize: 10

                                        text:
                                            partitionRow.index
                                            === diskItem.partitions.length - 1
                                            ? "└"
                                            : "├"
                                    }

                                    Text {
                                        Layout.preferredWidth: 72

                                        color: "#8b949e"

                                        font.pixelSize: 10
                                        font.family: "monospace"

                                        text:
                                            partitionRow.modelData.path
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true

                                        spacing: 0

                                        Text {
                                            Layout.fillWidth: true

                                            elide:
                                                Text.ElideRight

                                            color: "#c9d1d9"
                                            font.pixelSize: 10

                                            text:
                                                partitionRow.modelData.label
                                                && partitionRow.modelData.label.length > 0
                                                ? partitionRow.modelData.label
                                                : (
                                                    partitionRow.modelData.fstype
                                                    || I18n.t("partizione")
                                                  )
                                        }

                                        Text {
                                            Layout.fillWidth: true

                                            elide:
                                                Text.ElideRight

                                            color: "#484f58"

                                            font.pixelSize: 8
                                            font.family: "monospace"

                                            text:
                                                `${partitionRow.modelData.fstype || "?"}`
                                                + (
                                                    partitionRow.mounted
                                                    ? ` · ${partitionRow.modelData.mountpoint}`
                                                    : ""
                                                  )
                                        }
                                    }

                                    // Partizione già montata
                                    Rectangle {
                                        visible:
                                            partitionRow.mounted

                                        implicitWidth:
                                            unmountLabel.implicitWidth
                                            + 14

                                        implicitHeight: 20
                                        radius: 4

                                        color:
                                            unmountHover.hovered
                                            ? "#3d1418"
                                            : "#21262d"

                                        border.width: 1

                                        border.color:
                                            unmountHover.hovered
                                            ? "#f85149"
                                            : "#30363d"

                                        Text {
                                            id: unmountLabel

                                            anchors.centerIn: parent

                                            color:
                                                unmountHover.hovered
                                                ? "#f85149"
                                                : "#c9d1d9"

                                            font.pixelSize: 9

                                            text:
                                                I18n.t("Smonta")
                                        }

                                        HoverHandler {
                                            id: unmountHover

                                            cursorShape:
                                                Qt.PointingHandCursor
                                        }

                                        TapHandler {
                                            onTapped:
                                                win.unmountPartition(
                                                    partitionRow.modelData.path
                                                )
                                        }
                                    }

                                    // Partizione non montata ma montabile
                                    Rectangle {
                                        visible:
                                            !partitionRow.mounted
                                            && partitionRow.mountable

                                        implicitWidth:
                                            mountLabel.implicitWidth
                                            + 14

                                        implicitHeight: 20
                                        radius: 4

                                        color:
                                            mountHover.hovered
                                            ? "#1f6feb"
                                            : "#21262d"

                                        border.width: 1

                                        border.color:
                                            mountHover.hovered
                                            ? "#58a6ff"
                                            : "#30363d"

                                        Text {
                                            id: mountLabel

                                            anchors.centerIn: parent

                                            color:
                                                mountHover.hovered
                                                ? "#ffffff"
                                                : "#c9d1d9"

                                            font.pixelSize: 9

                                            text:
                                                I18n.t("Monta")
                                        }

                                        HoverHandler {
                                            id: mountHover

                                            cursorShape:
                                                Qt.PointingHandCursor
                                        }

                                        TapHandler {
                                            onTapped:
                                                win.mountPartition(
                                                    partitionRow.modelData.path
                                                )
                                        }
                                    }

                                    // LUKS, swap o filesystem non montabile
                                    Text {
                                        visible:
                                            !partitionRow.mounted
                                            && !partitionRow.mountable

                                        color: "#484f58"
                                        font.pixelSize: 9

                                        text:
                                            partitionRow.modelData.fstype
                                            === "crypto_LUKS"
                                            ? "LUKS"
                                            : partitionRow.modelData.fstype
                                              === "swap"
                                              ? "swap"
                                              : I18n.t("non montabile")
                                    }
                                }
                            }
                        }
                    }

                    Behavior on Layout.preferredHeight {
                        NumberAnimation {
                            duration: 150
                            easing.type:
                                Easing.OutQuad
                        }
                    }
                }
            }

            // ================================================== sensori

            Text {
                Layout.topMargin: 10

                color: "#8b949e"
                font.pixelSize: 10
                font.letterSpacing: 1

                text: I18n.t("SENSORI")
            }

            Text {
                Layout.fillWidth: true

                wrapMode: Text.Wrap
                color: "#6e7681"
                font.pixelSize: 10

                text:
                    I18n.t(
                        "Le sonde di temperatura che il kernel espone. Di partenza sono accese quelle della CPU e dei dischi; le altre sono qui perche' esistono, non perche' vogliano dire qualcosa — una scheda madre ne dichiara sei senza dire cosa misurino."
                    )
            }

            Repeater {
                model: SystemStats.sensorKeys

                Rectangle {
                    id: sensorRow

                    required property string modelData

                    readonly property var probe:
                        SystemStats.sensor(
                            sensorRow.modelData
                        )

                    readonly property bool on:
                        Settings.sensors.includes(
                            sensorRow.modelData
                        )

                    visible:
                        sensorRow.probe !== null

                    Layout.fillWidth: true

                    implicitHeight: 34
                    radius: 6

                    color:
                        sensorHover.hovered
                        ? "#161b22"
                        : "transparent"

                    border.width: 1

                    border.color:
                        sensorRow.on
                        ? "#30363d"
                        : "transparent"

                    HoverHandler {
                        id: sensorHover

                        cursorShape:
                            Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped:
                            Settings.toggleSensor(
                                sensorRow.modelData
                            )
                    }

                    RowLayout {
                        anchors.fill: parent

                        anchors.leftMargin: 8
                        anchors.rightMargin: 8

                        spacing: 8

                        Rectangle {
                            implicitWidth: 32
                            implicitHeight: 18
                            radius: 9

                            color:
                                sensorRow.on
                                ? "#1f6feb"
                                : "#21262d"

                            border.width: 1

                            border.color:
                                sensorRow.on
                                ? "#58a6ff"
                                : "#30363d"

                            Rectangle {
                                width: 12
                                height: 12
                                radius: 6

                                anchors.verticalCenter:
                                    parent.verticalCenter

                                x:
                                    sensorRow.on
                                    ? parent.width
                                      - width
                                      - 3
                                    : 3

                                color:
                                    sensorRow.on
                                    ? "#ffffff"
                                    : "#6e7681"

                                Behavior on x {
                                    NumberAnimation {
                                        duration: 120
                                    }
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            Text {
                                Layout.fillWidth: true

                                elide:
                                    Text.ElideRight

                                color:
                                    sensorRow.on
                                    ? "#c9d1d9"
                                    : "#8b949e"

                                font.pixelSize: 11

                                text:
                                    !sensorRow.probe
                                    ? ""
                                    : (
                                        sensorRow.probe.disk.length > 0
                                        ? `${sensorRow.probe.disk} · ${sensorRow.probe.label}`
                                        : sensorRow.probe.label
                                      )
                            }

                            Text {
                                Layout.fillWidth: true

                                elide:
                                    Text.ElideRight

                                color: "#484f58"

                                font.pixelSize: 9
                                font.family: "monospace"

                                text:
                                    !sensorRow.probe
                                    ? ""
                                    : (
                                        sensorRow.probe.crit > 0
                                        ? I18n.t(
                                            "%1 · limite %2 °C"
                                          )
                                          .arg(
                                              sensorRow.probe.chip
                                          )
                                          .arg(
                                              sensorRow.probe.crit
                                          )
                                        : sensorRow.probe.chip
                                      )
                            }
                        }

                        Rectangle {
                            implicitWidth: 54
                            implicitHeight: 6
                            radius: 3

                            color: "#21262d"

                            Rectangle {
                                width:
                                    parent.width
                                    * SystemStats.tempPercent(
                                        sensorRow.probe
                                    )
                                    / 100

                                height: parent.height
                                radius: 3

                                color:
                                    SystemStats.tempColor(
                                        sensorRow.probe
                                    )
                            }
                        }

                        Text {
                            Layout.minimumWidth: 56

                            horizontalAlignment:
                                Text.AlignRight

                            color: "#8b949e"
                            font.pixelSize: 10

                            text:
                                `${SystemStats.tempOf(
                                    sensorRow.probe
                                ).toFixed(1)} °C`
                        }
                    }
                }
            }

            // =================================================== battito

            Text {
                Layout.topMargin: 10

                color: "#8b949e"
                font.pixelSize: 10
                font.letterSpacing: 1

                text: I18n.t("BATTITO")
            }

            Text {
                Layout.fillWidth: true

                wrapMode: Text.Wrap
                color: "#6e7681"
                font.pixelSize: 10

                text:
                    I18n.t(
                        "La chiave di HealthBridge, quella scritta sotto l'indirizzo nell'app del telefono. La porta è aperta a chiunque sia sulla rete di casa, e la chiave è ciò che distingue questa dashboard da chiunque altro: senza, il telefono non risponde. Si riscrive qui quando la si rigenera sul telefono."
                    )
            }

            // La chiave si cambia anche quando niente e' rotto.
            //
            // Il pannello del battito ne apre gia' uno, di campo, ma solo
            // quando la lettura fallisce reclamandola: e' il momento giusto per
            // chi non l'ha mai data, e nessun momento per chi l'ha appena
            // rigenerata sul telefono e vuole rimetterla a posto prima che il
            // grafico se ne accorga. Qui non serve che qualcosa vada storto.
            //
            // Non la si scrive da qui piu' di quanto la scriva il pannello:
            // tutti e due passano da `Fitbit.pair`, e da li' da phone_adb.py,
            // che e' l'unico posto che sa in quale file vive.
            RowLayout {
                id: healthKey

                // Quella registrata si rilegge all'apertura invece di tenerne
                // una copia qui: una copia sarebbe una cosa in piu' da
                // aggiornare quando il pannello del battito cambia la chiave
                // mentre questa finestra e' chiusa.
                Component.onCompleted: Fitbit.readToken()

                onVisibleChanged: {
                    if (healthKey.visible)
                        Fitbit.readToken();
                }

                Layout.fillWidth: true

                spacing: 6

                Rectangle {
                    Layout.fillWidth: true

                    implicitHeight: 30
                    radius: 6

                    color: "#161b22"

                    border.width: 1

                    border.color:
                        keyInput.activeFocus
                        ? "#58a6ff"
                        : "#30363d"

                    TextInput {
                        id: keyInput

                        // La chiave non si nasconde mentre la si scrive: sta
                        // gia' in chiaro sullo schermo del telefono da cui la
                        // si copia, e mascherarla toglierebbe solo il modo di
                        // accorgersi di un carattere sbagliato.
                        anchors.fill: parent

                        anchors.leftMargin: 10
                        anchors.rightMargin: 10

                        verticalAlignment: TextInput.AlignVCenter

                        clip: true
                        color: "#c9d1d9"
                        font.pixelSize: 12
                        font.family: "monospace"

                        selectionColor: "#1f6feb"

                        enabled: !Fitbit.pairing

                        // Nove caratteri di un alfabeto senza le lettere che si
                        // confondono con le cifre: e' cosi' che l'app la
                        // genera, e filtrare qui evita di mandare allo script
                        // una chiave che non puo' essere giusta.
                        maximumLength: 9

                        validator: RegularExpressionValidator {
                            regularExpression: /[a-hj-km-np-z2-9]*/
                        }

                        text: Fitbit.token

                        onAccepted:
                            Fitbit.pair(keyInput.text)

                        Keys.onEscapePressed:
                            keyInput.text = Fitbit.token

                        // Il binding con `token` si spezza al primo carattere
                        // scritto, che e' giusto — ma allora una chiave data
                        // dal pannello del battito mentre questa finestra e'
                        // aperta non comparirebbe mai qui dentro.
                        Connections {
                            target: Fitbit

                            function onTokenChanged() {
                                keyInput.text = Fitbit.token;
                            }
                        }

                        Text {
                            anchors.verticalCenter:
                                parent.verticalCenter

                            visible: keyInput.text === ""

                            color: "#484f58"
                            font.pixelSize: 12

                            text:
                                I18n.t("la chiave scritta nell'app, poi Invio")
                        }
                    }
                }

                Rectangle {
                    id: keyButton

                    readonly property bool ready:
                        keyInput.text !== "" && !Fitbit.pairing

                    implicitWidth: keyLabel.implicitWidth + 20
                    implicitHeight: 30
                    radius: 6

                    color:
                        keyHover.hovered && keyButton.ready
                        ? "#21262d"
                        : "transparent"

                    border.width: 1

                    border.color:
                        keyButton.ready
                        ? "#30363d"
                        : "#21262d"

                    HoverHandler {
                        id: keyHover

                        cursorShape:
                            keyButton.ready
                            ? Qt.PointingHandCursor
                            : Qt.ArrowCursor
                    }

                    TapHandler {
                        enabled: keyButton.ready

                        onTapped:
                            Fitbit.pair(keyInput.text)
                    }

                    Text {
                        id: keyLabel

                        anchors.centerIn: parent

                        color:
                            keyButton.ready
                            ? "#c9d1d9"
                            : "#484f58"

                        font.pixelSize: 11

                        text:
                            Fitbit.pairing
                            ? I18n.t("collego…")
                            : I18n.t("Collega")
                    }
                }
            }

            // Com'e' andata, o cosa manca. `health-pair` prova la chiave
            // subito, quindi qui c'e' gia' la risposta del telefono e non solo
            // la conferma di aver scritto un file — che sarebbe la sola cosa
            // che si sa quando si salva senza provare.
            Text {
                Layout.fillWidth: true

                wrapMode: Text.Wrap
                font.pixelSize: 10

                visible: text !== ""

                color:
                    Fitbit.pairError || Fitbit.needsToken
                    ? "#d29922"
                    : "#6e7681"

                text: {
                    if (Fitbit.pairing)
                        return I18n.t("provo la chiave sul telefono…");
                    if (Fitbit.pairError)
                        return Fitbit.pairError;
                    if (Fitbit.needsToken)
                        return Fitbit.lastError;
                    if (!Fitbit.token)
                        return I18n.t("nessuna chiave registrata");
                    return "";
                }
            }

            Text {
                Layout.fillWidth: true

                wrapMode: Text.Wrap
                color: "#6e7681"
                font.pixelSize: 10

                text:
                    I18n.t(
                        "Quale telefono ha il braccialetto al polso. AUTO va bene finche' ne e' collegato uno solo: con due, il pannello non puo' indovinare quale, e lo dice invece di leggere il battito sbagliato."
                    )
            }

            RowLayout {
                id: heartPick

                // AUTO, i telefoni che adb vede adesso, e — se non e' fra
                // quelli — quello salvato. Senza l'ultimo pezzo la scelta
                // scritta nel file sparirebbe dalla riga ogni volta che il
                // telefono e' spento, e la riga direbbe AUTO: cioe' una scelta
                // diversa da quella che vale davvero.
                readonly property var options: {
                    const out = [
                        {
                            code: "",
                            label: I18n.t("AUTO")
                        }
                    ];

                    for (const name of PhoneAdb.phones)
                        out.push({
                            code: name,
                            label: name
                        });

                    if (Settings.heartDevice && !PhoneAdb.phones.includes(Settings.heartDevice))
                        out.push({
                            code: Settings.heartDevice,
                            label: Settings.heartDevice
                        });

                    return out;
                }

                Layout.fillWidth: true

                spacing: 4

                // Una guardata a ogni apertura della finestra: un telefono
                // acceso dopo l'ultima volta deve comparire da se'. Anche alla
                // creazione, perche' la prima apertura non cambia `visible` —
                // la riga nasce gia' visibile, e senza questa il primo giro
                // mostrerebbe il solo AUTO.
                Component.onCompleted: PhoneAdb.peek()

                onVisibleChanged: {
                    if (heartPick.visible)
                        PhoneAdb.peek();
                }

                Repeater {
                    model: heartPick.options

                    Rectangle {
                        id: phoneButton

                        required property var modelData

                        readonly property bool current:
                            Settings.heartDevice
                            === phoneButton.modelData.code

                        Layout.fillWidth: true

                        implicitHeight: 24
                        radius: 4

                        color:
                            phoneButton.current
                            ? "#21262d"
                            : "transparent"

                        border.width: 1

                        border.color:
                            phoneButton.current
                            ? "#58a6ff"
                            : "#30363d"

                        Text {
                            anchors.fill: parent
                            anchors.margins: 4

                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight

                            color:
                                phoneButton.current
                                ? "#58a6ff"
                                : "#6e7681"

                            font.pixelSize: 10

                            text:
                                phoneButton.modelData.label
                        }

                        MouseArea {
                            anchors.fill: parent

                            cursorShape:
                                Qt.PointingHandCursor

                            onClicked:
                                Settings.setHeartDevice(
                                    phoneButton.modelData.code
                                )
                        }
                    }
                }
            }

            // ================================================= priorità

            Text {
                Layout.topMargin: 10

                color: "#8b949e"
                font.pixelSize: 10
                font.letterSpacing: 1

                text: I18n.t("PRIORITÀ RICORDATE")
            }

            Text {
                Layout.fillWidth: true

                wrapMode: Text.Wrap
                color: "#6e7681"
                font.pixelSize: 10

                text:
                    I18n.t(
                        "Priorità che la dashboard riapplica a ogni avvio del programma, entro un paio di secondi: bassa e molto bassa lo mandano in secondo piano anche sul disco, normale vuol dire che va lasciato dov'è. Si aggiungono dal menu di un processo, con il tasto destro nella finestra dei processi."
                    )
            }

            Text {
                Layout.fillWidth: true

                visible:
                    Settings.priorityRules.length === 0

                wrapMode: Text.Wrap
                color: "#484f58"
                font.pixelSize: 10

                text:
                    I18n.t("nessuna regola")
            }

            Repeater {
                model: Settings.priorityRules

                Rectangle {
                    id: ruleRow

                    required property string modelData

                    readonly property string name:
                        ruleRow.modelData.slice(
                            0,
                            ruleRow.modelData.lastIndexOf(":")
                        )

                    readonly property int level:
                        parseInt(
                            ruleRow.modelData.slice(
                                ruleRow.modelData.lastIndexOf(":") + 1
                            )
                        )

                    readonly property int matches:
                        Processes.all
                        .filter(
                            p => p.name === ruleRow.name
                        )
                        .length

                    Layout.fillWidth: true

                    implicitHeight: 34
                    radius: 6

                    color:
                        ruleHover.hovered
                        ? "#161b22"
                        : "transparent"

                    border.width: 1
                    border.color: "#30363d"

                    HoverHandler {
                        id: ruleHover
                    }

                    RowLayout {
                        anchors.fill: parent

                        anchors.leftMargin: 8
                        anchors.rightMargin: 8

                        spacing: 8

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            Text {
                                Layout.fillWidth: true

                                elide:
                                    Text.ElideRight

                                color: "#c9d1d9"
                                font.pixelSize: 11

                                text:
                                    ruleRow.name
                            }

                            Text {
                                Layout.fillWidth: true

                                elide:
                                    Text.ElideRight

                                color: "#484f58"
                                font.pixelSize: 9

                                text:
                                    ruleRow.matches > 0
                                    ? I18n.tn(
                                        ruleRow.matches,
                                        "1 processo in esecuzione",
                                        "%1 processi in esecuzione"
                                      )
                                    : I18n.t(
                                        "non in esecuzione"
                                      )
                            }
                        }

                        Text {
                            color: "#8b949e"
                            font.pixelSize: 10

                            text:
                                ruleRow.level > 0
                                ? `nice ${ruleRow.level}`
                                : I18n.t("normale")
                        }

                        Rectangle {
                            implicitWidth: 24
                            implicitHeight: 22
                            radius: 4

                            color:
                                forgetHover.hovered
                                ? "#3d1418"
                                : "transparent"

                            border.width: 1

                            border.color:
                                forgetHover.hovered
                                ? "#f85149"
                                : "#30363d"

                            HoverHandler {
                                id: forgetHover

                                cursorShape:
                                    Qt.PointingHandCursor
                            }

                            Text {
                                anchors.centerIn: parent

                                color:
                                    forgetHover.hovered
                                    ? "#f85149"
                                    : "#8b949e"

                                font.pixelSize: 12
                                text: "×"
                            }

                            TapHandler {
                                onTapped:
                                    Settings.forgetPriority(
                                        ruleRow.name
                                    )
                            }
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true

                visible:
                    Settings.priorityRules.length > 0

                wrapMode: Text.Wrap
                color: "#484f58"
                font.pixelSize: 9

                text:
                    I18n.t(
                        "Togliere una regola non rialza i processi già avviati: riportare su una priorità richiede privilegi di amministratore. Alla prossima apertura del programma la priorità sarà normale."
                    )
            }

            // =================================================== parametri

            Text {
                Layout.topMargin: 10

                color: "#8b949e"
                font.pixelSize: 10
                font.letterSpacing: 1

                text: I18n.t("PARAMETRI")
            }

            Repeater {
                model: [
                    {
                        name: "topCount",
                        label: I18n.t("Processi per classifica"),
                        step: 1,
                        suffix: ""
                    },
                    {
                        name: "historyHours",
                        label: I18n.t(
                            "Ore di storico Home Assistant"
                        ),
                        step: 1,
                        suffix: " h"
                    },
                    {
                        name: "sampleInterval",
                        label: I18n.t(
                            "Campionamento sistema"
                        ),
                        step: 500,
                        suffix: " ms"
                    },
                    {
                        name: "haPollInterval",
                        label: I18n.t(
                            "Aggiornamento Home Assistant"
                        ),
                        step: 5000,
                        suffix: " ms"
                    },
                    {
                        name: "procInterval",
                        label: I18n.t(
                            "Campionamento processi"
                        ),
                        step: 500,
                        suffix: " ms"
                    },
                    {
                        name: "heartWindowHours",
                        label: I18n.t(
                            "Ore di storico battito"
                        ),
                        step: 1,
                        suffix: " h"
                    }
                ]

                Rectangle {
                    id: paramRow

                    required property var modelData

                    readonly property int value:
                        Settings[
                            paramRow.modelData.name
                        ]

                    readonly property var limits:
                        Settings.limitsFor(
                            paramRow.modelData.name
                        )

                    Layout.fillWidth: true

                    implicitHeight: 32
                    radius: 6

                    color:
                        paramHover.hovered
                        ? "#161b22"
                        : "transparent"

                    border.width: 1
                    border.color: "#30363d"

                    HoverHandler {
                        id: paramHover
                    }

                    RowLayout {
                        anchors.fill: parent

                        anchors.leftMargin: 8
                        anchors.rightMargin: 6

                        spacing: 6

                        Text {
                            Layout.fillWidth: true

                            elide:
                                Text.ElideRight

                            color: "#c9d1d9"
                            font.pixelSize: 11

                            text:
                                paramRow.modelData.label
                        }

                        Text {
                            color: "#484f58"
                            font.pixelSize: 9

                            text:
                                `${paramRow.limits[0]}–${paramRow.limits[1]}`
                        }

                        Repeater {
                            model: [
                                {
                                    delta: -1,
                                    label: "−"
                                },
                                {
                                    delta: 1,
                                    label: "+"
                                }
                            ]

                            Rectangle {
                                id: stepButton

                                required property var modelData

                                readonly property int target:
                                    paramRow.value
                                    + stepButton.modelData.delta
                                      * paramRow.modelData.step

                                readonly property bool allowed:
                                    stepButton.target
                                    >= paramRow.limits[0]
                                    && stepButton.target
                                       <= paramRow.limits[1]

                                implicitWidth: 22
                                implicitHeight: 20
                                radius: 4

                                color:
                                    stepHover.hovered
                                    && stepButton.allowed
                                    ? "#21262d"
                                    : "transparent"

                                border.width: 1
                                border.color: "#30363d"

                                opacity:
                                    stepButton.allowed
                                    ? 1
                                    : 0.35

                                HoverHandler {
                                    id: stepHover
                                }

                                Text {
                                    anchors.centerIn: parent

                                    color: "#8b949e"
                                    font.pixelSize: 11

                                    text:
                                        stepButton.modelData.label
                                }

                                MouseArea {
                                    anchors.fill: parent

                                    enabled:
                                        stepButton.allowed

                                    cursorShape:
                                        Qt.PointingHandCursor

                                    onClicked:
                                        Settings.setParam(
                                            paramRow.modelData.name,
                                            stepButton.target
                                        )
                                }
                            }
                        }

                        Text {
                            Layout.minimumWidth: 54

                            horizontalAlignment:
                                Text.AlignRight

                            color: "#c9d1d9"

                            font.pixelSize: 11
                            font.bold: true

                            text:
                                paramRow.value
                                + paramRow.modelData.suffix
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.topMargin: 6

                wrapMode: Text.Wrap
                color: "#484f58"
                font.pixelSize: 9
                font.family: "monospace"

                text:
                    "~/.config/quickshell/dashboard.json"
            }
        }

        ScrollBar {
            anchors.right: parent.right

            height: parent.height

            view: scroll
        }
    }
}