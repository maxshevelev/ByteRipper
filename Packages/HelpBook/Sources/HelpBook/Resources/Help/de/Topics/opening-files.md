@source-sha 3ac1ba2bc6d063174996e8014146026eb8b2d993abeff2e2ab36b34b84168484
# Dateien öffnen: A und B

> Das Fenster hat zwei Plätze. Eine Datei ist schlicht ein Editor; eine zweite Datei fügt den Vergleich hinzu. Bearbeiten geht in beiden Bereichen, so oder so.

Das Fenster hält zwei Dateiplätze, **Datei A** und **Datei B**. Wo eine Datei landet, entscheidet, was geschieht:

- **Eine Datei offen** — Einzeldatei-Modus. Das Fenster ist ein Hex-Editor für diese Datei; Bearbeiten, Suchen und die Firmware-Panels arbeiten wie gewohnt.
- **Zwei Dateien offen** — Vergleichsmodus. Die Dumps stehen nebeneinander (oder übereinander, siehe **Darstellung ▸ Fensteraufteilung wechseln**), und jedes abweichende Byte ist gefärbt.

Datei B ist optional. Außer dem Vergleich selbst braucht nichts eine zweite Datei.

## Wege, einen Dump zu öffnen

- **Ablage ▸ Öffnen…** (⌘O). Sind beide Plätze belegt, fragt das Programm, welcher ersetzt werden soll.
- **Ziehen und Ablegen.** Ziehen Sie eine Datei aufs Fenster; die Ablagebänder zeigen, wo sie landet — diesen Bereich ersetzen, daneben öffnen, in einem neuen Tab öffnen. Zwei Dateien auf einmal belegen beide Plätze.
- **Ablage ▸ Benutzte Dokumente** — die Dumps, die Sie zuletzt offen hatten.
- **Aus dem Finder**, wenn ByteRipper als Programm für die Endung eingetragen ist (siehe [[topic:settings|Einstellungen]]).
- **Ablage ▸ Neue Datei** (⌘N) legt eine leere unbenannte Datei an — ein Ort, in den sich Bytes einsetzen lassen.

## Bereiche, Tabs und Fenster

Jeder Bereichskopf nennt seine Datei, ihre Größe und ob es ungesicherte Änderungen gibt. Das ✕ im Kopf schließt diesen Bereich und lässt den anderen offen.

Ein Fenster kann mehrere Tabs halten (**Ablage ▸ Neuer Tab**, ⌘T), jeder mit eigenem Plätzepaar. So hält man mehrere Platinen auf einem Bildschirm auseinander: ein Tab pro Auftrag.

## Wenn die Datei schon offen ist

Eine Datei zu öffnen, die bereits im anderen Platz liegt, ist erlaubt — eine Datei mit sich selbst zu vergleichen, während man eine Kopie bearbeitet, ist durchaus sinnvoll. Sie in den Platz zu öffnen, in dem sie schon liegt, tut nichts.

! Einen Bereich mit ungesicherten Änderungen zu ersetzen, fragt vorher nach. Für einen verworfenen Bereich gibt es kein Zurück.

Siehe auch: [[topic:join-duplicate|Zusammenfügen und Duplizieren]], [[topic:large-files|Große Dumps]].
