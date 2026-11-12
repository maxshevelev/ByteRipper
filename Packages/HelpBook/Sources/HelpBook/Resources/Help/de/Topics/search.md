@source-sha 2142edf3386d611920f54156b47799542ed823f1e068eeb0056df5f2334c0309
# Bytes und Text finden

> ⌘F. Suche nach einer Byte-Folge oder einer Zeichenfolge über den ganzen Dump, im Hintergrund.

Die Suchleiste durchsucht den **aktiven Bereich** über seinen aktuellen Inhalt, ungesicherte Änderungen eingeschlossen.

## Suchleiste des Tabs und der Fragment-Bereiche

Jede Suchleiste ist dem Dump zugeordnet, in dem sie sucht. Im Tab befindet sie sich oberhalb der Vergleichsbereiche und der Minimap; durchsucht wird der jeweils aktive Bereich. Jeder [[topic:fragments|Fragment-Bereich]] verfügt über eine eigene Suchleiste oberhalb seines Dumps, deren Suche sich auf die Bytes des Fragments beschränkt. ⌘F, ⌘G, Esc sowie die Taste **Suchen** in der Symbolleiste beziehen sich stets auf die Suchleiste des vordersten Bereichs.

Muster, Treffer und die Einstellung zur Groß-/Kleinschreibung werden für jede Suchleiste getrennt geführt; Suchvorgänge im Fragment und im Tab beeinflussen einander daher nicht. Ein neu geöffneter Fragment-Bereich übernimmt die Einstellung zur Groß-/Kleinschreibung aus der Suchleiste des Bereichs, dem das Fragment entnommen wurde. Beim Einklappen des Bereichs in seine Pille im Dock wird auch die Suchleiste eingeklappt; nach dem Aufklappen steht sie unverändert wieder zur Verfügung.

## Hex

Eine Byte-Folge wird als `DEADBEEF`, `DE AD BE EF` oder `0xDE 0xAD` eingegeben; Leerzeichen sind freigestellt. Nach dem Start der Suche wird das Feld in der Schreibweise neu gesetzt, die der Dump selbst verwendet — Großbuchstabenpaare mit je einem Leerzeichen —, damit sich das Muster an die Bytes auf dem Bildschirm halten lässt.

Eine Hex-Suche ist immer exakt. Bytes haben keine Groß- und Kleinschreibung, und die entsprechende Option wird dafür deshalb nicht angeboten.

## Text

Es wird eine Codierung gewählt — ASCII, UTF-8, UTF-16 LE oder UTF-16 BE — und die Zeichenfolge eingegeben. Sie wird in Bytes codiert und exakt auf diesen Bytes gesucht.

Für Text wird die Suche ohne Rücksicht auf Groß- und Kleinschreibung angeboten.

## Intelligente Suche

Eine Zeichenfolge in einem Dump steht in der Codierung, die der Hersteller der Firmware gerade verwendet hat, und der Lesende weiß in der Regel, **was** er sucht, und nicht, **wie es geschrieben ist**. Die Intelligente Suche nimmt diese Frage weg: Die Codierung wird zum Ergebnis der Suche statt zu ihrer Bedingung. Deshalb ist sie voreingestellt — es gibt meist nichts, worauf sich eine Wahl der Codierung vorab stützen könnte.

Das Eingegebene wird in einer Form nach der anderen gesucht, bis etwas gefunden wird:

- Liest es sich als Byte-Folge — eine gerade Anzahl von Hex-Ziffern, `DEADBEEF`, oder dieselben Ziffern paarweise, `DE AD BE EF` —, wird es zuerst als Bytes und erst danach als Text gesucht.
- Sonst werden die Codierungen der Reihe nach durchprobiert: ASCII, UTF-8, dann UTF-16 LE und UTF-16 BE.
- Eine Codierung, die das Eingegebene überhaupt nicht darstellen kann, entfällt: In ihr gibt es nichts zu suchen.
- Versuche, die auf dieselben Bytes hinauslaufen, werden zu einem Durchlauf zusammengefasst. `abc` als ASCII und als UTF-8 sind dieselben drei Bytes, und der Dump wird für eine Antwort nicht zweimal gelesen.

Die Codierung, die den Treffer geliefert hat, bleibt im Einblendmenü ausgewählt — so wird die Antwort auf die nicht gestellte Frage sichtbar. Wird nichts gefunden, nennt das Programm die Codierungen, die es probiert hat.

Eine von Hand gewählte Codierung legt fest, wo die Suche beginnt; ebenso ein Eintrag aus dem Suchverlauf, der seine eigene Codierung mitbringt. In den seltenen Fällen, in denen die Intelligente Suche danebengreift oder mehr findet als gemeint war, wird sie ausgeschaltet, und es wird nur die gewählte Codierung durchsucht.

## Während eine Suche läuft

Jeder Treffer in der Datei ist grau gefüllt; der aktuelle wird als angehobene gelbe Blase dargestellt. **‹ ›** bewegen zwischen ihnen, und die Leiste nennt die Anzahl. Über einen großen Dump läuft die Suche im Hintergrund und lässt sich abbrechen; die Treffer erscheinen, während sie gefunden werden.

Die Treffer werden auch in der [[topic:minimap|Minimap]] markiert, in der ihre Verteilung über das Image sichtbar wird.

**Suchergebnisse** in der Suchleiste öffnet eine Liste des Gefundenen, die sich durchklicken lässt; ein erneuter Druck schließt sie.

## Häufig gebrauchte Muster

**⌘E** übernimmt die aktuelle Auswahl als Suchmuster, ohne eine Suche zu starten; so wird eine in einem Dump ausgewählte Folge im anderen gesucht.

**Nächstes suchen** (⌘G) und **Vorheriges suchen** (⇧⌘G) im Menü **Bearbeiten** springen wie **‹ ›** zum nächsten und zum vorherigen Treffer des Musters in der Suchleiste und öffnen die Leiste, wenn sie geschlossen ist; die Tastatur bleibt, wo sie war. Außerdem legen ⌘E und jede Suche ihr Muster in der Suchzeichenfolge ab, die macOS für alle Programme gemeinsam führt; über sie enthalten alle Suchfelder von ByteRipper dasselbe Muster: die Suchleiste jedes Tabs und jedes Fragment-Panels, das Feld des [[topic:tool-uefi|UEFI-Baums]] und das Feld, mit dem das Code-Panel alle Funktionen eines Moduls durchsucht. Wird in einem Feld gesucht, erscheint das Muster sofort in den übrigen geöffneten Feldern; ein geschlossenes Feld übernimmt es beim Öffnen. Ein in einem anderen Programm gesuchtes Muster gelangt in die geöffneten Felder, sobald ByteRipper wieder das aktive Programm ist. ⌘G sucht nach demselben Muster. Ein eingegebenes Muster, nach dem noch nicht gesucht wurde, bleibt im Feld, bis in einem anderen Feld oder in einem anderen Programm eine Suche läuft.

Muster lassen sich benennen und in einer Musterbibliothek halten (**Einstellungen ▸ Suchmuster**) — etwa regelmäßig gebrauchte Signaturen wie `_FVH`, `$FPT` oder `24 00 00 00`. Die Bibliothek lässt sich über einen Ordner abgleichen, sodass mehrere Installationen dieselbe verwenden.

Siehe auch: [[topic:bookmarks|Lesezeichen]], um eine gefundene Adresse zu markieren.
