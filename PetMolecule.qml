import QtQuick

// Una molecola sola, disegnata da una descrizione.
//
// Sta in un file suo perche' la disegnano in due: la nuvola nella stanza
// (PetMolecules) e l'anteprima nella finestra delle caratteristiche
// (PetTraitRow). Due copie dello stesso disegno comincerebbero uguali e
// finirebbero diverse — e la seconda e' proprio quella che serve a fidarsi
// della prima.
//
// La forma non e' scritta qui: arriva come dato da PetTraits.molecules, dove
// stanno CO2, H2O, O3, CH4 e le altre. Aggiungerne una e' una riga di elenco,
// non una riga di codice.
Item {
    id: mol

    // La descrizione: { atoms: [{ cx, cy, d, center }], bonds: [{ a, b, double }] }
    // in unita' di disegno, con l'origine dove capita — ci pensa il riquadro
    // qui sotto a rimetterla in squadro.
    property var spec: null

    // Quanti pixel vale un'unita'. Nella stanza e' la scala intera del pet,
    // nell'anteprima e' quello che ci sta.
    property real unit: 2

    // I tre colori, scelti da chi configura la caratteristica.
    //
    // Non virano: chi li sceglie se li tiene. A dire che l'aria e' cattiva
    // restano il numero di molecole, quanto salgono e la barra — che sono tre
    // segnali, e bastano.
    property color outerColor: "#58a6ff"
    property color centerColor: "#8b949e"
    property color bondColor: "#8b949e"

    readonly property var atoms: mol.spec && mol.spec.atoms ? mol.spec.atoms : []
    readonly property var bonds: mol.spec && mol.spec.bonds ? mol.spec.bonds : []

    // Il riquadro che contiene tutto, atomi presi col loro raggio. Serve per
    // dare a questo Item una misura vera: senza, una molecola piegata sarebbe
    // alta quanto una lineare e uscirebbe dai bordi della stanza.
    readonly property var box: {
        if (mol.atoms.length === 0)
            return {
                x0: 0,
                y0: 0,
                w: 1,
                h: 1
            };
        let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
        for (const a of mol.atoms) {
            const r = a.d / 2;
            x0 = Math.min(x0, a.cx - r);
            x1 = Math.max(x1, a.cx + r);
            y0 = Math.min(y0, a.cy - r);
            y1 = Math.max(y1, a.cy + r);
        }
        return {
            x0: x0,
            y0: y0,
            w: Math.max(0.1, x1 - x0),
            h: Math.max(0.1, y1 - y0)
        };
    }

    implicitWidth: mol.box.w * mol.unit
    implicitHeight: mol.box.h * mol.unit
    width: implicitWidth
    height: implicitHeight

    // Da coordinate della descrizione a pixel dentro questo Item.
    function px(v) {
        return (v - mol.box.x0) * mol.unit;
    }

    function py(v) {
        return (v - mol.box.y0) * mol.unit;
    }

    // ---- I legami, sotto agli atomi -----------------------------------------
    // Disegnati per primi cosi' spariscono sotto i cerchi invece di
    // attraversarli: e' il modo in cui si disegnano le molecole da sempre, e a
    // venti pixel e' anche l'unico che non sembra un errore.
    Repeater {
        model: mol.bonds

        Item {
            id: bond

            required property var modelData

            readonly property var from: mol.atoms[bond.modelData.a]
            readonly property var to: mol.atoms[bond.modelData.b]

            readonly property real x1: mol.px(bond.from.cx)
            readonly property real y1: mol.py(bond.from.cy)
            readonly property real x2: mol.px(bond.to.cx)
            readonly property real y2: mol.py(bond.to.cy)

            readonly property real len: Math.hypot(bond.x2 - bond.x1, bond.y2 - bond.y1)

            // Il legame e' una barra ruotata: due atomi qualunque, anche in
            // diagonale, e non serve un caso a parte per le molecole piegate.
            // Item.Left e' il punto di mezzo del lato sinistro, quindi la
            // barra ruota attorno al centro dell'atomo di partenza — che e'
            // esattamente dove deve stare la cerniera. Da cui il -height/2:
            // sposta la barra in su di meta' spessore perche' il suo asse
            // cada sul centro dell'atomo e non sul suo bordo.
            x: bond.x1
            y: bond.y1 - bond.height / 2
            width: bond.len
            height: Math.max(1, mol.unit * 1.1)
            transformOrigin: Item.Left
            rotation: Math.atan2(bond.y2 - bond.y1, bond.x2 - bond.x1) * 180 / Math.PI

            // Doppio quando la descrizione lo chiede E c'e' spazio per farlo
            // vedere: sotto una certa scala due barre separate da mezzo pixel
            // sono una barra sola sfocata, e allora se ne disegna una.
            readonly property bool twin: bond.modelData.double === true && mol.unit >= 3

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                y: bond.twin ? 0 : (parent.height - height) / 2
                height: Math.max(1, mol.unit * (bond.twin ? 0.35 : 0.45))
                color: mol.bondColor
                antialiasing: true
            }

            Rectangle {
                visible: bond.twin
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Math.max(1, mol.unit * 0.35)
                color: mol.bondColor
                antialiasing: true
            }
        }
    }

    // ---- Gli atomi ----------------------------------------------------------
    Repeater {
        model: mol.atoms

        Rectangle {
            required property var modelData

            width: modelData.d * mol.unit
            height: width
            radius: width / 2
            x: mol.px(modelData.cx) - width / 2
            y: mol.py(modelData.cy) - height / 2
            color: modelData.center === true ? mol.centerColor : mol.outerColor
            antialiasing: true
        }
    }
}
