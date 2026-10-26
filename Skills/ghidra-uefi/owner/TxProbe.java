// Phase 0: run under analyzeHeadless with -postScript, it shows that a
// headless script runs inside the launcher's transaction and cannot save.
import ghidra.app.script.GhidraScript;
public class TxProbe extends GhidraScript {
    @Override
    public void run() throws Exception {
        println("TXPROBE tx=" + currentProgram.getCurrentTransactionInfo()
                + " modnum=" + currentProgram.getModificationNumber());
        try {
            currentProgram.save("probe", monitor);
            println("TXPROBE save ok");
        } catch (Exception error) {
            println("TXPROBE save failed: " + error);
        }
    }
}
