@source-sha 0ffc10a7cf76da1406aab9639dc1da91e830e09258da88b0c99cb7d8c5fea050
# Der Arbeitsbereich

> Bei eingeschalteter Einstellung öffnet ByteRipper beim Start, was beim Beenden geöffnet war.

Die Einstellung heißt **Arbeitsbereich beim Start wiederherstellen** und befindet sich in den [[topic:settings|Einstellungen ▸ Allgemein]]. Nach der Installation ist sie ausgeschaltet: Am Reparaturplatz ist jeder Auftrag eine andere Platine, und Dumps eines früheren Auftrags, die sich von selbst öffnen, wären hinderlich.

## Was wiederhergestellt wird

- Die Fenster und ihre Tabs in ihrer Reihenfolge, Größe und Lage; vorn liegt derselbe Tab.
- In jedem Tab File A und File B, der aktive Bereich und die Lage der Trennlinie zwischen ihnen.
- In jedem Bereich die Adresse in der obersten Bildschirmzeile, Cursor und Auswahl, die Hex- oder Textspalte und der Einfügemodus.
- Die [[topic:bookmarks|Lesezeichen]] und die [[topic:segments|Segmente]]: Schnitte, Namen und die Verknüpfungen der Segmente mit den Dateien, aus denen sie zusammengefügt wurden.
- Die [[topic:fragments|Fragment-Bereiche]] samt dem, der vorn lag, sowie Teile, die in eigene Tabs verschoben wurden. Ein Teil wird nicht als Bytes gespeichert, sondern erneut aus seiner Datei entnommen; er zeigt daher deren aktuellen Inhalt und lässt sich weiterhin zurückschreiben, gleich in welchem Tab oder Fenster diese Datei liegt.
- **Nie gesicherte Dokumente** — eine neue Datei, ein Zusammenfügen, ein Duplikat, auch wenn es einen Namen erhalten hat — mit ihren Bytes und weiterhin ungesichert, sowie Teile mit Änderungen, die noch nicht in ihre Datei zurückgeschrieben sind, samt diesen Änderungen. Sie werden während der Arbeit neben dem Arbeitsbereich aufbewahrt, gehen daher auch bei einem unplanmäßigen Ende nicht verloren, und beim Beenden fragt das Programm nicht nach ihnen.
- **Ungesicherte Änderungen an Dateien auf dem Datenträger**, die rot und weiterhin ungesichert zurückkehren, wie sie waren. Neben dem Arbeitsbereich werden nur die geänderten Bytes aufbewahrt, keine Kopie der Datei. Wie nie gesicherte Dokumente gehen sie bei einem unplanmäßigen Ende nicht verloren, und beim Beenden fragt das Programm nicht nach ihnen. Die Änderungen werden nur dann wieder auf die Datei gelegt, wenn es dieselbe Datei ist, an der sie vorgenommen wurden (siehe unten).
- **Der Widerrufsverlauf** jedes Dokuments — Dateien auf dem Datenträger, nie gesicherte Dokumente, Teile — mit dem, was sich noch wiederholen lässt. Nach einem Neustart widerruft ⌘Z die Änderungen von davor: Die Schnitte der Segmente kehren mit ihnen zurück, das Widerrufen eines Zusammenfügens verbindet das Dokument wieder mit seiner Datei, und das Widerrufen bis zum auf dem Datenträger gesicherten Stand macht eine Datei wieder ungeändert. Der Verlauf hält sich an die Grenzen, die unter [[topic:editing|Bytes bearbeiten]] festgelegt sind. Der Name eines Schritts im Menü „Bearbeiten“ bleibt in der Sprache, in der das Programm lief, als die Änderung vorgenommen wurde.
- Das [[topic:notes|Anmerkungen-Fenster]] an seinem Platz zwischen den Tabs oder als eigenes Fenster, mit den Karten, die ausgewählt waren.
- Die [[topic:minimap|Minimap]], die Suchleiste mit ihrem Muster sowie der Werkzeugbereich mit dem darin gewählten Knoten oder der gewählten Zeile und den geöffneten Zweigen des UEFI-Baums.

## Was nicht wiederhergestellt wird

- Die Verbindung eines Teils mit seiner Datei, wenn diese Datei fehlt oder sich geändert hat: Der Teil kehrt mit seinen Änderungen als nie gesichertes Dokument zurück.
- Der Verlauf von Zurück / Vorwärts und die Ergebnisse von Search All.
- Einstellungen wie Schrift, Wortbreite und Anordnung der Bereiche. Sie werden getrennt gespeichert und gelten ohnehin.

## Wann der Arbeitsbereich geschrieben wird

Fortlaufend: alle paar Sekunden, solange das Programm im Vordergrund ist, beim Wechsel in den Hintergrund, beim Schließen eines Fensters und beim Beenden. Das Schließen des letzten Fensters beendet ByteRipper genau wie **⌘Q**, und der Arbeitsbereich behält dieses Fenster. Das Ausschalten der Einstellung löscht den gespeicherten Arbeitsbereich.

Der Arbeitsbereich liegt in `~/Library/Application Support/ByteRipper/Workspace` und verlässt diesen Mac nicht.

## Geänderte und fehlende Dateien

Beim Start wird jede Datei mit der Größe und dem Änderungsdatum verglichen, die sie hatte, als der Arbeitsbereich geschrieben wurde. Eine Datei, über der ungesicherte Änderungen aufbewahrt werden, wird zusätzlich nach ihrem Inhalt verglichen (SHA-256): Ein Kopieren oder eine Datensicherung ändert das Datum einer Datei, ohne ein Byte zu ändern. Eine Datei, bei der sich nur das Datum geändert hat, behält daher ihre Änderungen, und eine Datei mit anderen Bytes gilt als geändert, auch wenn ihr Datum gleich geblieben ist. Das Lesen einer Datei von mehreren Gigabyte dauert einige Sekunden, ebenso das Zurücklesen eines langen Verlaufs, der für sie aufbewahrt wird; währenddessen zeigt ihr Fenster den Fortschritt der Arbeit und lässt sich nicht bearbeiten, denn die Änderungen werden erst auf die Datei gelegt, wenn sie geprüft ist.

- Eine Datei, die nicht mehr unter ihrem Pfad liegt, wird nicht geöffnet.
- Eine geänderte Datei wird geöffnet. Ist sie kürzer geworden, gehen Cursor und Bildschirm auf ihre letzte Adresse, und Lesezeichen hinter ihrem Ende werden entfernt. Ihre ungesicherten Änderungen, ihre Segmente, ihre Teile und der Zustand ihres Werkzeugbereichs werden nicht wiederhergestellt: Sie beziehen sich auf andere Bytes und würden auf falsche Stellen zeigen.

In beiden Fällen nennt eine Meldung nach der Wiederherstellung die betroffenen Dateien.

Ebenso werden die Änderungen geprüft, die ByteRipper neben dem Arbeitsbereich aufbewahrt. Änderungen, die sich nicht genau so zurücklesen lassen, wie sie geschrieben wurden – die Dateien neben dem Arbeitsbereich sind beschädigt –, werden nicht angewendet: Die Datei öffnet sich so, wie sie auf dem Datenträger liegt, ein Teil so, wie seine Datei ihn enthält, und ein Dokument ohne Datei wird nicht geöffnet. Die Meldung nach der Wiederherstellung nennt sie. Führt der aufbewahrte Verlauf nicht mehr bis zu seinem Anfang zurück, kehrt der Inhalt so zurück, wie er war, jedoch ohne die Schritte, ihn zu widerrufen, und auch das sagt die Meldung.

## Eine Datei aus dem Finder öffnen

Wird ByteRipper durch das Öffnen einer Datei im Finder gestartet, wird zuerst der Arbeitsbereich wiederhergestellt, und die Datei öffnet sich in einem neuen Tab. Eine Datei, die im Arbeitsbereich bereits geöffnet ist, wird nicht ein zweites Mal geöffnet: Ihr Tab wird nach vorn geholt.
