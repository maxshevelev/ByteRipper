@source-sha 06b42111ba3c7f7b1b5a73f3e3efd1ecb7015c19d3b5c1e6f8ef00a9302bfa1b
# Wer in den Flash schreibt

> Nur der Chipsatz hat Leitungen zum Chip. Alles auf der Platine, das Firmware schreiben will, muss ihn fragen — und wer was fragen darf, entscheidet der Descriptor.

Bytes kommen auf zwei Wegen in den Flash-Chip, und aus dem Unterschied folgt fast alles, was in der Werkstatt Rätsel aufgibt.

- **Über den Chipsatz**, während die Platine läuft. Der einzige SPI-Controller der Platine sitzt im [[term:pch|Chipsatz]], also kommen die Firmware auf der CPU, ein Flash-Werkzeug, die [[term:me|Management Engine]] und der Netzwerk-Controller nur über ihn an den Chip.
- **An den Beinchen des Chips selbst**, mit einem [[term:programmer|Programmer]] — Klammer, Sockel oder in der Schaltung. Der Chipsatz ist daran nicht beteiligt und auf einer Platine in Reparatur meist nicht einmal versorgt.

Der erste Weg wird kontrolliert. Der zweite nicht.

## Die Platine schreibt ständig in ihren eigenen Flash

Und nicht nur, wenn jemand die Firmware aktualisiert:

- Sie ändern eine Einstellung im Setup und drücken F10, und die Firmware schreibt den [[term:vss|NVRAM]]-Speicher zurück in die [[term:bios-region|BIOS-Region]].
- Die Management Engine schreibt ihre eigene [[term:mfs|MFS]]: Konfiguration, Zähler, Zustand.
- Ein Update-Werkzeug des Herstellers oder Intels FPT schreibt aus dem laufenden System eine ganze Region neu.

Ein heute gelesener Chip und die Datei, die gestern hineingeschrieben wurde, stimmen deshalb nicht überein, auch wenn niemand die Platine absichtlich angefasst hat: NVRAM und MFS haben sich von selbst bewegt. Das ist das Erste, was zu vermuten ist, wenn ein Vergleich Unterschiede zeigt, für die es keine Erklärung gibt.

## Was der Descriptor entscheidet

Der [[term:flash-descriptor|Descriptor]] nennt vier [[term:flash-master|Master]] — BIOS, ME, GbE und EC — und gibt jedem eine Lese- und eine Schreibmaske über die [[term:region|Regionen]]. Ein Flash-Werkzeug, das auf der CPU läuft, *ist* der BIOS-Master. Wo der Descriptor diesem Master kein Schreibrecht auf eine Region gibt, weist der Chipsatz den Schreibvorgang ab, und Wiederholen ändert daran nichts.

! Lesen ist genauso geregelt, und das trifft am härtesten. Eine Region, die der BIOS-Master nicht lesen darf, lässt sich aus dem laufenden System überhaupt nicht auslesen. Manche Programme verweigern das Lesen des ganzen Chips, andere füllen das Ungelesene mit `FF` und geben eine Warnung aus. `FF` in einem im System erstellten Dump kann also „durfte nicht gelesen werden“ heißen statt „gelöscht“ — und der Vergleich zeigt dann eine ganze Region als einen riesigen Unterschied, den es gar nicht gibt. Ein Dump vom Programmer hat solche Löcher nicht.

## Schreiben heißt nicht Ausführen

Die Masken entscheiden nur eines: ob geschrieben werden darf. Ob das Geschriebene dann läuft, ist eine andere Frage, und sie wird beim Start beantwortet, von Prüfungen, die mit dem Descriptor nichts zu tun haben:

- [[term:boot-guard|Boot Guard]] prüft den Bootblock, bevor die CPU ihn ausführt. Die Signatur prüft nicht der Chipsatz: das tut das [[term:acm|ACM]], gestartet vom Mikrocode der CPU, und der Hash des Wurzelschlüssels liegt in den [[term:otp|Fuses]] des Chipsatzes.
- Die ME-Region prüft die Engine selbst, während sie hochkommt.

Daher die Trennung, an der eine Änderung scheitert, die sauber geschrieben wurde. Ein Programmer umgeht die Masken — er kann jedes Byte in jede Region schreiben. Gegen die Prüfungen beim Start richtet er nichts aus: eine Änderung innerhalb des [[term:ibb|IBB]] oder in der ME-Region wird geschrieben und danach abgewiesen.

Alles aber, was diese Prüfungen nicht abdecken — NVRAM, der [[term:dmi|DMI]]-Bereich, die [[term:ec|EC]]-Firmware und oft auch die DXE-Treiber ([[term:ibb|IBB / OBB]] sagt, wann) —, schreibt ein Programmer, und es läuft. Darauf ruht die Reparatur.

## Die Sperren, von denen der Descriptor nichts weiß

Der Descriptor ist nur eine von mehreren Schranken, und die übrigen liegen in Registern des Chipsatzes, nicht im Image:

- **BIOS Lock Enable** — der Versuch, das Schreiben in die BIOS-Region freizugeben, fällt in den System-Management-Modus, wo der Handler der Firmware selbst entscheidet.
- **SMM BIOS Write Protect** — die BIOS-Region ist nur beschreibbar, solange der Prozessor im System-Management-Modus ist.
- **Protected Range Registers** — bis zu fünf Adressbereiche, die die Firmware beim Start sperrt; sie halten sogar gegen den System-Management-Modus.
- **Flash Configuration Lockdown** — friert diese Bereiche bis zum nächsten Plattform-Reset ein.

Nichts davon steht im Dump, also kann kein Bereich es zeigen und keine Änderung es ändern. Es erklärt aber einen Schreibvorgang, der abgewiesen wird, obwohl der Descriptor ihn klar erlaubt.

## Der Service-Übergang

Intels Chipsätze tragen einen **Flash Descriptor Security Override**: einen Strap, gedacht für die Fertigung, der vollen Lese- und Schreibzugriff auf alle Regionen öffnet. Manche Desktop-Platinen führen ihn als Jumper heraus; auf Notebooks ist es meist ein Pin des Audio-Codecs, der beim Einschalten gehalten werden muss. Damit entsperren Service-Prozeduren einen Descriptor, ohne die Platine für einen Programmer zu öffnen. Intel dokumentiert das nicht öffentlich: Was die Reparatur-Community darüber weiß, ist gemessen und nicht aus einem Datenblatt gelesen. Siehe [[topic:provenance|Woher dieses Wissen stammt]].

Siehe auch: [[topic:bench-safety|Regeln am Arbeitsplatz]], [[term:flash-descriptor|Flash descriptor]].
