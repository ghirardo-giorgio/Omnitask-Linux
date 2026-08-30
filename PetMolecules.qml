import QtQuick

// L'aria della stanza, disegnata.
//
// Una barra dice «CO2 1120 ppm» e va letta; una stanza che si riempie di
// molecole si capisce con un'occhiata, che e' il punto di avere un pet invece
// di un grafico. Questo componente e' roba nostra e sta nella radice, non in
// pet/: quella cartella e' di terzi e resta com'e' (vedi pet/UPSTREAM.md).
//
// Non e' un sistema di particelle di QtQuick: quello vorrebbe una texture, non
// saprebbe disegnare O=C=O e costerebbe molto di piu' di quanto serva per far
// galleggiare qualche decina di cosine. Il disegno della singola molecola sta
// in PetMolecule.qml, che serve anche all'anteprima delle opzioni.
Item {
    id: field

    // La caratteristica risolta da PetTraits: serve `value`, `wellness` e la
    // sezione `particle` con forma, colori e passo. null = niente da disegnare.
    property var trait: null

    // La scala intera del pet. Le molecole la seguono per stare nella stessa
    // proporzione degli sprite: a pannello piu' grande, pet piu' grande e
    // molecole piu' grandi, invece di una nuvola di puntini fissi attorno a un
    // pet che cresce.
    property int scale: 2

    // Il tetto: quante se ne disegnano al massimo, qualunque cosa dica il
    // sensore. Non e' una scelta estetica ma un limite di costo — a quaranta
    // sono gia' qualche centinaio di elementi di scenegraph, e oltre la stanza
    // non dice niente di nuovo mentre il conto continua a salire.
    property int maxCount: 40

    // Ferma tutto quando nessuno guarda. Come ogni altro timer della stanza:
    // il pannello resta costruito per tutto il tempo in cui gira la shell.
    property bool running: true

    readonly property var spec: field.trait && field.trait.particle ? field.trait.particle : null

    // ---- Quante ------------------------------------------------------------
    //
    // 🔴 Una molecola ogni `step` unita' VERE sopra `base`, non una frazione
    // del campo della barra. La differenza conta: con la regola di prima, un
    // campo 400-2000 e uno 400-5000 mostravano la stessa nuvola sullo stesso
    // valore, perche' contava la posizione dentro il campo e non i ppm. Adesso
    // «una molecola ogni 40 ppm» vuol dire quello che dice, e allargare il
    // fondoscala non cambia piu' l'aria della stanza.
    //
    // A `base` sono zero, ed e' giusto: quattrocento ppm e' l'aria di fuori, e
    // l'aria di fuori non si vede.
    readonly property int count: {
        if (!field.spec || !field.trait || field.trait.value === null)
            return 0;
        const step = field.spec.step > 0 ? field.spec.step : 1;
        const n = Math.floor((field.trait.value - field.spec.base) / step);
        return Math.max(0, Math.min(field.maxCount, n));
    }

    // Quanto in alto arriva l'aria cattiva.
    //
    // La CO2 e' piu' pesante dell'aria e ristagna in basso davvero: a valori
    // buoni le molecole restano sul pavimento e salgono man mano che se ne
    // accumulano. Non e' solo giusto in fisica — e' anche il modo in cui si
    // vede che sta peggiorando senza contare le molecole una per una.
    //
    // Si misura sul riempimento raggiunto rispetto al tetto, non sul benessere:
    // cosi' la nuvola sale insieme al suo stesso numero, invece di saltare in
    // alto quando una soglia scritta a mano viene superata.
    readonly property real ceiling: 0.35 + 0.65 * (field.maxCount > 0 ? field.count / field.maxCount : 0)

    // Poche e trasparenti quando ce ne sono poche, piu' presenti quando sono
    // tante: senza, cinque molecole ben visibili sembrerebbero un allarme.
    readonly property real strength: 0.35 + 0.45 * (field.maxCount > 0 ? field.count / field.maxCount : 0)

    // 🔴 Un solo Timer per tutte, e nessun lavoro per fotogramma. A ogni giro
    // ogni molecola riceve una destinazione nuova e ci arriva con una
    // NumberAnimation lunga quanto il giro: il JavaScript gira 0,4 volte al
    // secondo e l'interpolazione la fa il scenegraph. Un Timer per molecola, o
    // un onFrame, costerebbero quaranta volte tanto per lo stesso risultato.
    readonly property int stepMs: 2500

    property int tick: 0

    Timer {
        interval: field.stepMs
        running: field.running && field.count > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: field.tick++
    }

    Repeater {
        model: field.count

        Item {
            id: molecule

            required property int index

            // Ogni molecola ha la sua andatura, decisa una volta dal suo indice
            // e non a ogni giro: senza, tutte si muoverebbero con lo stesso
            // passo e la nuvola pulserebbe invece di fluttuare.
            readonly property real drift: 0.4 + (molecule.index % 7) / 10

            // La misura viene dalla molecola, e la molecola sta a (0,0): un
            // `anchors.centerIn: parent` qui chiuderebbe il cerchio — la
            // dimensione del genitore dipende dal figlio, la posizione del
            // figlio dal genitore. La rotazione gira gia' attorno al centro
            // per difetto, che con le due misure uguali e' il centro giusto.
            width: shape.implicitWidth
            height: shape.implicitHeight

            opacity: field.strength

            // Le destinazioni. Si ricalcolano quando `tick` cambia — e solo
            // allora: leggere `field.tick` dentro il binding e' cio' che lo
            // lega al Timer senza che serva un handler.
            //
            // Il margine e' meta' della diagonale e non meta' della larghezza,
            // perche' la molecola ruota: nel punto peggiore del giro sporge di
            // quanto e' lunga la diagonale, e senza questo verrebbe tagliata
            // dal bordo della stanza proprio mentre passa di traverso.
            readonly property real reach: Math.hypot(molecule.width, molecule.height) / 2

            readonly property real targetX: {
                const _ = field.tick;
                const span = Math.max(1, field.width - 2 * molecule.reach);
                return molecule.reach - molecule.width / 2 + Math.random() * span;
            }

            readonly property real targetY: {
                const _ = field.tick;
                const top = field.height * (1 - field.ceiling);
                const span = Math.max(1, field.height - top - 2 * molecule.reach);
                return top + molecule.reach - molecule.height / 2 + Math.random() * span;
            }

            x: molecule.targetX
            y: molecule.targetY

            Behavior on x {
                NumberAnimation {
                    duration: field.stepMs * molecule.drift * 2
                    easing.type: Easing.InOutSine
                }
            }

            Behavior on y {
                NumberAnimation {
                    duration: field.stepMs * molecule.drift * 2
                    easing.type: Easing.InOutSine
                }
            }

            // ---- Il ruzzolare --------------------------------------------
            //
            // Una molecola vera ruzzola, e ferma sembra un adesivo. Gira
            // sempre, lenta e ognuna per conto suo: verso alternato per parita'
            // dell'indice e periodo fra i 14 e i 32 secondi, cosi' non si
            // trovano mai in fase — due molecole sincronizzate si notano
            // subito e disfano l'illusione.
            //
            // Non costa: e' una RotationAnimation, cioe' interpolazione nel
            // scenegraph. Nessun JavaScript per fotogramma, come per il resto
            // di questo file. Si ferma con `running`, come tutto il resto.
            RotationAnimation on rotation {
                running: field.running
                loops: Animation.Infinite
                from: molecule.index % 2 === 0 ? 0 : 360
                to: molecule.index % 2 === 0 ? 360 : 0
                duration: 14000 + (molecule.index % 7) * 3000
            }

            PetMolecule {
                id: shape

                spec: field.spec ? field.spec.shape : null
                unit: field.scale
                outerColor: field.spec ? field.spec.outerColor : "#58a6ff"
                centerColor: field.spec ? field.spec.centerColor : "#8b949e"
                bondColor: field.spec ? field.spec.bondColor : "#8b949e"
            }
        }
    }
}
