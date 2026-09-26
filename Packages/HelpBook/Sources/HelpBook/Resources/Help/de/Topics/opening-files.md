@source-sha 8a6771703acb00d0e7a84ab62d9dcdb4ea8d78e6c9160f5ae9c91a8f8958bdce
# Dateien öffnen: ein Bereich oder zwei

> Ein Tab hält zwei Dateibereiche. Eine Datei ist schlicht ein Editor; eine zweite Datei fügt den Vergleich hinzu. Bearbeiten geht in beiden Bereichen, so oder so.

Wie viele der beiden Bereiche eine Datei halten, entscheidet, was das Fenster ist:

- **Eine Datei offen** — Einzeldatei-Modus. Das Fenster ist ein Hex-Editor für diese Datei; Bearbeiten, Suchen und die Werkzeugbereiche arbeiten wie gewohnt.
- **Zwei Dateien offen** — Vergleichsmodus. Die Dumps stehen nebeneinander (oder übereinander, siehe **Darstellung ▸ Fensteraufteilung wechseln**), und jedes abweichende Byte ist gefärbt.

Der zweite Bereich ist optional. Außer dem Vergleich selbst braucht nichts eine zweite Datei.

## Wege, einen Dump zu öffnen

- **Ablage ▸ Öffnen…** (⌘O). Sind beide Bereiche leer, füllen die ersten beiden gewählten Dateien sie; ist einer frei, geht die Datei dorthin; sind beide belegt, ersetzt sie den **aktiven** Bereich. Was darüber hinaus gewählt ist, wird nicht geöffnet.
- **Ziehen und Ablegen.** Ziehen Sie eine Datei aufs Fenster; die Ablagebänder zeigen, wo sie landet — diesen Bereich ersetzen, daneben öffnen, in einem neuen Tab öffnen. Zwei Dateien auf einmal: die zweite öffnet im anderen Bereich, sofern dieser frei ist.
- **Ablage ▸ Benutzte Dokumente** — die Dumps, die Sie zuletzt offen hatten.
- **Aus dem Finder**, wenn ByteRipper als Programm für die Endung eingetragen ist (siehe [[topic:settings|Einstellungen]]).
- **Ablage ▸ Neue Datei** (⌘N) legt eine leere unbenannte Datei an — ein Ort, in den sich Bytes einsetzen lassen.

## Bereiche, Tabs und Fenster

Jeder Bereichskopf nennt seine Datei und ob es ungesicherte Änderungen gibt; die Größe steht in der Statuszeile darunter. Das ✕ im Kopf schließt diesen Bereich und lässt den anderen offen.

Ein Fenster kann mehrere Tabs halten (**Ablage ▸ Neuer Tab**, ⌘T), jeder mit eigenem Paar Dateibereiche. So hält man mehrere Platinen auf einem Bildschirm auseinander: ein Tab pro Auftrag.

## Wenn die Datei schon offen ist

Eine Datei ist immer nur an einer Stelle geöffnet, und daran hält sich das Programm:

- **Im anderen Bereich dieses Tabs** — es lehnt ab und sagt es. Derselbe Dump kann nicht in beiden Bereichen liegen, eine Datei lässt sich also nicht mit sich selbst vergleichen.
- **In einem anderen Tab oder Fenster** — es bietet die Wahl: die Datei dort zeigen, wo sie offen ist, oder jenen Bereich in dieses Tab holen.
- **Im selben Bereich** — es liest die Datei neu von der Platte. Bei ungesicherten Änderungen fragt es vorher, denn das Neulesen verwirft sie.

! Einen Bereich mit ungesicherten Änderungen zu ersetzen, fragt vorher nach. Für einen verworfenen Bereich gibt es kein Zurück.

Siehe auch: [[topic:join-duplicate|Zusammenfügen und Duplizieren]], [[topic:large-files|Große Dumps]].
