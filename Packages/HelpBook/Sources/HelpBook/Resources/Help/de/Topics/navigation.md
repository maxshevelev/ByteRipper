@source-sha 1ece1b5e9062445d3daf3c010a9d12debe5901e6810706a0378badfdfd03a8c1
# Sich bewegen

> Zwischen Unterschieden springen, zu einer Adresse springen oder auf einem Byte stehen und ablesen, wo man ist.

## Zwischen Unterschieden

- **⌥⌘→** — nächster Unterschied, **⌥⌘←** — vorheriger.
- **⇧⌥⌘→ / ⇧⌥⌘←** — nächster / vorheriger **gleicher** Block: der Anfang der nächsten Strecke, auf der die Dateien übereinstimmen. Nützlich, wenn sich fast das ganze Image unterscheidet und man die Inseln sucht, die passen.

Ein „Unterschied“ ist beim Springen eine ganze Folge abweichender Bytes, nicht jedes einzelne: ein abweichender 4-KB-Block ist eine Station, nicht viertausend.

## Zu einer Adresse

**⌘L** öffnet „Gehe zu“. Geben Sie eine Adresse ein und drücken Sie Return:

- `0x1FE00` — hexadezimal, mit dem Präfix `0x` (es steht schon im Feld).
- `130560` — dezimal, ohne Präfix.

Das Feld merkt sich die letzten zehn Adressen, zu denen Sie gesprungen sind. Darunter liegt die [[topic:bookmarks|Lesezeichenliste]] — Tab bringt die Tastatur dorthin, Return springt zum ausgewählten Lesezeichen. Beide Hälften sind ein Fenster, weil sie eine Frage beantworten.

Im Vergleichsmodus bewegt der Sprung **beide** Bereiche: sie sind an dieselbe Adresse gebunden, und genau das macht die Ansicht nebeneinander überhaupt sinnvoll.

## Einen Block auswählen

**Bearbeiten ▸ Block auswählen…** wählt einen Bereich über Zahlen statt über die Maus: Anfang und Ende, oder Anfang und Länge. Beide Felder nehmen Hex mit `0x` und schlichtes Dezimal. Das ist der verlässliche Weg, eine Region auszuwählen, deren Grenzen Sie in einem Werkzeugbereich abgelesen haben.

! Bereiche sind intern halboffen — die Endadresse ist das erste Byte, das **nicht** dazugehört. Dialoge dürfen ein einschließendes Ende anbieten; sie rechnen es um.

## Den anderen Bereich mitführen

Die beiden Bereiche bleiben gekoppelt: Scrollposition, Einfügemarke und Auswahl. Das macht einen Vergleich lesbar. **Darstellung ▸ Bereiche tauschen** vertauscht A und B, falls Sie sie andersherum geöffnet haben.

Siehe auch: [[topic:minimap|Die Minimap]] — sich durch Zeigen bewegen statt über Adressen.
