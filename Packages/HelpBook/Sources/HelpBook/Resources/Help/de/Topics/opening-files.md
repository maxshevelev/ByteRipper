@source-sha ad462ea419b965b93eedbfdeb1b82fd5d6c49f565688379845f79ceed77c5dfb
# Dateien öffnen: ein Bereich oder zwei

> Ein Tab hält zwei Dateibereiche. Eine Datei ist schlicht ein Editor; eine zweite Datei fügt den Vergleich hinzu. Bearbeiten geht in beiden Bereichen, so oder so.

Wie viele der beiden Bereiche eine Datei halten, entscheidet, was das Fenster ist:

- **Eine Datei offen** — Einzeldatei-Modus. Das Fenster ist ein Hex-Editor für diese Datei; Bearbeiten, Suchen und die Werkzeugbereiche arbeiten wie gewohnt.
- **Zwei Dateien offen** — Vergleichsmodus. Die Dumps stehen nebeneinander (oder übereinander, siehe **Darstellung ▸ Fensteraufteilung wechseln**), und jedes abweichende Byte ist gefärbt.

Der zweite Bereich ist optional. Außer dem Vergleich selbst braucht nichts eine zweite Datei.

## Wege, einen Dump zu öffnen

- **Ablage ▸ Öffnen…** (⌘O). Die Datei ersetzt den **aktiven** Bereich; einen zweiten Bereich legt der Befehl nicht von selbst an. Nur wenn beide Bereiche leer sind, füllen die ersten beiden gewählten Dateien sie. Was darüber hinaus gewählt ist, wird nicht geöffnet.
- **Ablage ▸ Vergleichen mit…** (⌥⌘O) öffnet die Datei im anderen Bereich: im freien, sonst im nicht aktiven. So kommt die zweite Datei für den Vergleich hinzu. Bei **Ablage ▸ Benutzte Dokumente** wird die Zeile mit gedrückter ⌥-Taste zum selben Befehl.
- **Ziehen und Ablegen.** Ziehen Sie eine Datei aufs Fenster; die Ablagebänder zeigen, wo sie landet — diesen Bereich ersetzen, daneben öffnen, in einem neuen Tab öffnen. Zwei Dateien auf einmal: die zweite öffnet im anderen Bereich, sofern dieser frei ist.
- **Ablage ▸ Benutzte Dokumente** — die Dumps, die Sie zuletzt offen hatten.
- **Aus dem Finder**, wenn ByteRipper als Programm für die Endung eingetragen ist (siehe [[topic:settings|Einstellungen]]).
- **Ablage ▸ Neue Datei** (⌘N) legt eine leere unbenannte Datei an — ein Ort, in den sich Bytes einsetzen lassen.

## Bereiche, Tabs und Fenster

Jeder Bereichskopf nennt seine Datei und ob es ungesicherte Änderungen gibt; die Größe steht in der Statuszeile darunter. Das ✕ im Kopf schließt diesen Bereich und lässt den anderen offen.

Ein Fenster kann mehrere Tabs halten (**Ablage ▸ Neuer Tab**, ⌘T), jeder mit einem eigenen Paar Dateibereiche zum Vergleichen. So werden in einem Fenster mehrere voneinander unabhängige Vergleiche geführt: BIOS-Dumps im einen Tab, Dumps des Embedded Controllers im nächsten.

## Wenn die Datei schon offen ist

Eine Datei ist immer nur an einer Stelle geöffnet, und das Programm setzt das durch:

- **Im anderen Bereich dieses Tabs** — es lehnt ab und nennt den Grund. Dieselbe Datei kann nicht beide Bereiche belegen, eine Datei lässt sich also nicht mit sich selbst vergleichen. Ungesicherte Änderungen sind ohnehin rot gekennzeichnet; werden zwei Kopien nebeneinander gebraucht, erzeugt **Ablage ▸ Duplizieren** eine.
- **In einem anderen Tab oder Fenster** — es bietet die Wahl: die Datei dort zeigen, wo sie geöffnet ist, oder jenen Bereich in dieses Tab holen.
- **Im selben Bereich** — es liest die Datei neu vom Volume. Hält der Bereich ungesicherte Änderungen, fragt es vorher, da das Neulesen sie verwirft.

! Die Datei in einem Bereich mit ungesicherten Änderungen zu ersetzen, verlangt eine Bestätigung. Verworfene Änderungen lassen sich nicht wiederherstellen.

Siehe auch: [[topic:join-duplicate|Zusammenfügen und Duplizieren]], [[topic:large-files|Große Dumps]].
