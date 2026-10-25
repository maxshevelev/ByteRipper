// Export one analyzed program as the rich, read-later code artifact.
//
//   analyzeHeadless ... -postScript ExportCode.java out.json
//
// The artifact is what the Code panel and an agent read after Ghidra is gone:
// every function with its decompiled C, every instruction with its bytes and
// references, the program's blocks, its strings, and the writes to the POST
// port. The JSON is intentionally explicit rather than compact; a module of a
// few kilobytes stays small, and a reader can see what was written.
// @category ByteRipper

import java.io.File;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.framework.Application;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.DataType;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.scalar.Scalar;

public class ExportCode extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) {
            println("usage: ExportCode.java <out.json>");
            return;
        }
        File out = new File(args[0]);

        Listing listing = currentProgram.getListing();
        StringBuilder json = new StringBuilder(1 << 22);
        json.append("{\n");
        json.append("  \"script_version\": 2,\n");
        json.append("  \"ghidra\": ").append(quote(Application.getApplicationVersion())).append(",\n");
        json.append("  \"program\": {\n");
        json.append("    \"name\": ").append(quote(currentProgram.getName())).append(",\n");
        json.append("    \"language\": ").append(quote(currentProgram.getLanguageID().toString())).append(",\n");
        json.append("    \"image_base\": ").append(quote(hex(currentProgram.getImageBase()))).append(",\n");
        json.append("    \"sha256\": ").append(quote(currentProgram.getExecutableSHA256())).append("\n");
        json.append("  },\n");

        // Blocks: the address ranges the program has, and whether they are code.
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

        // Strings worth naming: defined string data, at its address.
        List<String> strings = new ArrayList<>();
        DataIterator data = listing.getDefinedData(true);
        while (data.hasNext() && !monitor.isCancelled()) {
            Data item = data.next();
            DataType type = item.getDataType();
            if (type == null) continue;
            String typeName = type.getName();
            if (!typeName.toLowerCase().contains("string")) continue;
            Object value;
            try {
                value = item.getValue();
            } catch (Exception error) {
                continue;
            }
            if (value == null) continue;
            strings.add("{\"address\": " + quote(hex(item.getAddress()))
                + ", \"type\": " + quote(typeName)
                + ", \"value\": " + quote(value.toString()) + "}");
        }
        json.append("  \"strings\": [").append(String.join(", ", strings)).append("],\n");

        // Functions, in address order, with their instructions and decompiled C.
        DecompInterface decompiler = new DecompInterface();
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(false);
        decompiler.openProgram(currentProgram);

        List<Function> functions = new ArrayList<>();
        FunctionIterator iterator = currentProgram.getFunctionManager().getFunctions(true);
        while (iterator.hasNext() && !monitor.isCancelled()) functions.add(iterator.next());

        List<String> postCodes = new ArrayList<>();
        List<String> statusCodeCalls = new ArrayList<>();
        json.append("  \"functions\": [\n");
        for (int index = 0; index < functions.size(); index++) {
            Function function = functions.get(index);
            if (monitor.isCancelled()) break;
            json.append("    {\n");
            json.append("      \"entry\": ").append(quote(hex(function.getEntryPoint()))).append(",\n");
            json.append("      \"name\": ").append(quote(function.getName())).append(",\n");
            json.append("      \"size\": ").append(function.getBody().getNumAddresses()).append(",\n");
            json.append("      \"external\": ").append(function.isExternal()).append(",\n");
            json.append("      \"thunk\": ").append(function.isThunk()).append(",\n");
            json.append("      \"signature\": ").append(quote(function.getPrototypeString(false, false))).append(",\n");

            List<String> callers = new ArrayList<>();
            for (Function caller : function.getCallingFunctions(monitor)) callers.add(quote(hex(caller.getEntryPoint())));
            List<String> callees = new ArrayList<>();
            for (Function callee : function.getCalledFunctions(monitor)) callees.add(quote(hex(callee.getEntryPoint())));
            json.append("      \"callers\": [").append(String.join(", ", callers)).append("],\n");
            json.append("      \"callees\": [").append(String.join(", ", callees)).append("],\n");

            if (!function.isExternal() && !function.isThunk()) {
                DecompileResults results = decompiler.decompileFunction(function, 120, monitor);
                if (results != null && results.decompileCompleted()
                        && results.getDecompiledFunction() != null) {
                    json.append("      \"c\": ").append(quote(results.getDecompiledFunction().getC())).append(",\n");
                }
            }

            List<String> instructions = new ArrayList<>();
            List<String> recent = new ArrayList<>();
            InstructionIterator code = listing.getInstructions(function.getBody(), true);
            while (code.hasNext() && !monitor.isCancelled()) {
                Instruction instruction = code.next();
                String bytes = "";
                try {
                    bytes = hexBytes(instruction.getBytes());
                } catch (Exception ignored) {
                    // A partly mapped instruction still has text worth keeping.
                }
                List<String> references = new ArrayList<>();
                Reference[] refs = instruction.getReferencesFrom();
                for (Reference reference : refs) {
                    if (reference.getReferenceType().isFallthrough()) continue;
                    references.add("{\"to\": " + quote(hex(reference.getToAddress()))
                        + ", \"type\": " + quote(reference.getReferenceType().toString()) + "}");
                }
                String text = instruction.toString();
                // A call through a table entry at +0x58 is the PEI
                // ReportStatusCode call in a 32-bit PEI services table; the
                // pushes just before it carry Type and Value. A candidate,
                // because another table could use the same displacement.
                if (instruction.getFlowType().isCall() && text.matches(".*\\[\\s*\\w+\\s*\\+\\s*0x58\\s*\\].*")) {
                    List<String> context = new ArrayList<>(recent);
                    statusCodeCalls.add("{\"address\": " + quote(hex(instruction.getAddress()))
                        + ", \"function\": " + quote(hex(function.getEntryPoint()))
                        + ", \"text\": " + quote(text)
                        + ", \"context\": ["
                        + String.join(", ", context.stream().map(ExportCode::quote).toList())
                        + "]}");
                }
                instructions.add("{\"address\": " + quote(hex(instruction.getAddress()))
                    + ", \"bytes\": " + quote(bytes)
                    + ", \"mnemonic\": " + quote(instruction.getMnemonicString())
                    + ", \"text\": " + quote(text)
                    + ", \"flow\": " + quote(instruction.getFlowType().toString())
                    + ", \"references\": [" + String.join(", ", references) + "]}");

                // A write to the POST port is what a board's POST card shows.
                if ("OUT".equalsIgnoreCase(instruction.getMnemonicString())) {
                    String port = "";
                    Object[] operands = instruction.getOpObjects(0);
                    if (operands.length > 0 && operands[0] instanceof Scalar) {
                        port = hex(((Scalar) operands[0]).getUnsignedValue());
                    } else if (operands.length > 0) {
                        port = operands[0].toString();
                    }
                    postCodes.add("{\"address\": " + quote(hex(instruction.getAddress()))
                        + ", \"function\": " + quote(hex(function.getEntryPoint()))
                        + ", \"port\": " + quote(port)
                        + ", \"text\": " + quote(text) + "}");
                }
                recent.add(text);
                if (recent.size() > 8) recent.remove(0);
            }
            json.append("      \"instructions\": [\n        ")
                .append(String.join(",\n        ", instructions)).append("\n      ]\n");
            json.append("    }");
            if (index + 1 < functions.size()) json.append(",");
            json.append("\n");
        }
        json.append("  ],\n");
        json.append("  \"post_codes\": [").append(String.join(", ", postCodes)).append("],\n");
        json.append("  \"status_code_calls\": [")
            .append(String.join(", ", statusCodeCalls)).append("]\n");
        json.append("}\n");

        try (Writer writer = Files.newBufferedWriter(out.toPath(), StandardCharsets.UTF_8)) {
            writer.write(json.toString());
        }
        decompiler.dispose();
        println("wrote " + functions.size() + " functions to " + out);
    }

    private static String hex(Address address) {
        return "0x" + Long.toHexString(address.getOffset()).toUpperCase();
    }

    private static String hex(long value) {
        return String.format("0x%X", value);
    }

    private static String hexBytes(byte[] bytes) {
        StringBuilder builder = new StringBuilder();
        for (byte value : bytes) {
            if (builder.length() > 0) builder.append(' ');
            builder.append(String.format("%02X", value & 0xFF));
        }
        return builder.toString();
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
                    if (c < 0x20) builder.append(String.format("\\u%04x", (int) c));
                    else builder.append(c);
            }
        }
        return builder.append("\"").toString();
    }
}
