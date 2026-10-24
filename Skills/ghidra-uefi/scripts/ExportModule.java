// Export one program's functions, decompiled C and call relationships as JSON.
// For the headless path: analyzeHeadless ... -postScript ExportModule.java out.json
// @category ByteRipper

import java.io.File;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.mem.MemoryBlock;

public class ExportModule extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) {
            println("usage: ExportModule.java <out.json> [--no-decompile]");
            return;
        }
        File out = new File(args[0]);
        boolean decompile = true;
        for (int i = 1; i < args.length; i++) {
            if ("--no-decompile".equals(args[i])) {
                decompile = false;
            }
        }

        DecompInterface decompiler = null;
        if (decompile) {
            decompiler = new DecompInterface();
            decompiler.toggleCCode(true);
            decompiler.toggleSyntaxTree(false);
            decompiler.openProgram(currentProgram);
        }

        StringBuilder json = new StringBuilder(1 << 20);
        json.append("{\n");
        json.append("  \"program\": ").append(quote(currentProgram.getName())).append(",\n");
        json.append("  \"executable\": ").append(quote(currentProgram.getExecutablePath())).append(",\n");
        json.append("  \"language\": ").append(quote(currentProgram.getLanguageID().toString())).append(",\n");
        json.append("  \"image_base\": ").append(quote(hex(currentProgram.getImageBase()))).append(",\n");
        json.append("  \"sha256\": ").append(quote(currentProgram.getExecutableSHA256())).append(",\n");

        json.append("  \"blocks\": [");
        MemoryBlock[] blocks = currentProgram.getMemory().getBlocks();
        for (int i = 0; i < blocks.length; i++) {
            MemoryBlock block = blocks[i];
            if (i > 0) json.append(", ");
            json.append("{\"name\": ").append(quote(block.getName()))
                .append(", \"start\": ").append(quote(hex(block.getStart())))
                .append(", \"end\": ").append(quote(hex(block.getEnd())))
                .append(", \"executable\": ").append(block.isExecute())
                .append(", \"initialized\": ").append(block.isInitialized())
                .append("}");
        }
        json.append("],\n");

        List<Function> functions = new ArrayList<>();
        FunctionIterator iterator = currentProgram.getFunctionManager().getFunctions(true);
        while (iterator.hasNext() && !monitor.isCancelled()) {
            functions.add(iterator.next());
        }

        json.append("  \"function_count\": ").append(functions.size()).append(",\n");
        json.append("  \"functions\": [\n");
        for (int index = 0; index < functions.size(); index++) {
            Function function = functions.get(index);
            if (monitor.isCancelled()) break;
            json.append("    {\n");
            json.append("      \"name\": ").append(quote(function.getName())).append(",\n");
            json.append("      \"entry\": ").append(quote(hex(function.getEntryPoint()))).append(",\n");
            json.append("      \"size\": ").append(function.getBody().getNumAddresses()).append(",\n");
            json.append("      \"external\": ").append(function.isExternal()).append(",\n");
            json.append("      \"thunk\": ").append(function.isThunk()).append(",\n");
            json.append("      \"signature\": ").append(quote(function.getPrototypeString(false, false))).append(",\n");

            List<String> callers = new ArrayList<>();
            Set<Function> calling = function.getCallingFunctions(monitor);
            for (Function caller : calling) {
                callers.add(hex(caller.getEntryPoint()));
            }
            List<String> callees = new ArrayList<>();
            Set<Function> called = function.getCalledFunctions(monitor);
            for (Function callee : called) {
                callees.add(hex(callee.getEntryPoint()));
            }
            json.append("      \"callers\": ").append(stringArray(callers)).append(",\n");
            json.append("      \"callees\": ").append(stringArray(callees));

            if (decompiler != null && !function.isExternal() && !function.isThunk()) {
                DecompileResults results = decompiler.decompileFunction(function, 120, monitor);
                if (results != null && results.decompileCompleted()
                        && results.getDecompiledFunction() != null) {
                    json.append(",\n      \"c\": ").append(quote(results.getDecompiledFunction().getC()));
                }
            }
            json.append("\n    }");
            if (index + 1 < functions.size()) json.append(",");
            json.append("\n");
        }
        json.append("  ]\n}\n");

        try (Writer writer = Files.newBufferedWriter(out.toPath(), StandardCharsets.UTF_8)) {
            writer.write(json.toString());
        }
        if (decompiler != null) {
            decompiler.dispose();
        }
        println("wrote " + functions.size() + " functions to " + out);
    }

    private static String hex(Address address) {
        return "0x" + Long.toHexString(address.getOffset()).toUpperCase();
    }

    private static String stringArray(List<String> values) {
        StringBuilder builder = new StringBuilder("[");
        for (int i = 0; i < values.size(); i++) {
            if (i > 0) builder.append(", ");
            builder.append(quote(values.get(i)));
        }
        return builder.append("]").toString();
    }

    private static String quote(String value) {
        if (value == null) return "null";
        StringBuilder builder = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"': builder.append("\\\""); break;
                case '\\': builder.append("\\\\"); break;
                case '\n': builder.append("\\n"); break;
                case '\r': builder.append("\\r"); break;
                case '\t': builder.append("\\t"); break;
                case '\b': builder.append("\\b"); break;
                case '\f': builder.append("\\f"); break;
                default:
                    if (c < 0x20) {
                        builder.append(String.format("\\u%04x", (int) c));
                    } else {
                        builder.append(c);
                    }
            }
        }
        return builder.append("\"").toString();
    }
}
