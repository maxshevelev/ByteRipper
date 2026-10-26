import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import ghidra.GhidraApplicationLayout;
import ghidra.GhidraLaunchable;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.base.project.GhidraProject;
import ghidra.framework.Application;
import ghidra.framework.HeadlessGhidraApplicationConfiguration;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Program;
import ghidra.program.model.pcode.HighFunction;
import ghidra.program.model.pcode.HighFunctionDBUtil;
import ghidra.program.model.pcode.HighSymbol;
import ghidra.program.model.symbol.SourceType;
import ghidra.util.task.TaskMonitor;

import java.io.File;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;
import java.util.concurrent.Executors;

// Phase 0 of Design/GHIDRA_SHARED_PLAN.md: a long-lived headless Ghidra that
// owns one program and serves a few HTTP calls on loopback. Not the owner — the
// experiment that decided how the owner is built; its findings are in the
// plan's §3. Kept as the starting point for phase 1.
//
//   G=<ghidra install>; CP=$(find $G/Ghidra -path "*/lib/*.jar" | tr '\n' ':')
//   javac -proc:none -d classes -cp "$CP" Spike.java && jar cf spike.jar -C classes .
//   java -Djava.awt.headless=true -cp "$CP:spike.jar" Spike <project-dir> create 8765 <module>
//   java -Djava.awt.headless=true -cp "$CP:spike.jar" Spike <project-dir> own 8765 <program>
//
// `create` imports and analyzes; `open` opens through GhidraProject.openProgram
// (the standing-transaction trap); `own` opens through DomainFile, as the owner
// must. The project directory must not have a path element starting with '.'.
public class Spike implements GhidraLaunchable {
    private Program program;
    private GhidraProject project;
    private boolean own;

    @Override
    public void launch(GhidraApplicationLayout layout, String[] args) throws Exception {
        Application.initializeApplication(layout, new HeadlessGhidraApplicationConfiguration());
        String dir = args[0], mode = args[1];
        int port = Integer.parseInt(args[2]);
        if (mode.equals("create")) {
            File module = new File(args[3]);
            project = GhidraProject.createProject(dir, "spike", false);
            program = project.importProgram(module);
            GhidraProject.analyze(program);
            project.saveAs(program, "/", module.getName(), true);
        } else if (mode.equals("open")) {
            project = GhidraProject.openProject(dir, "spike");
            program = project.openProgram("/", args[3], false);
        } else {
            // Without GhidraProject's standing transaction: each change is
            // its own, and a failed one rolls back only itself.
            project = GhidraProject.openProject(dir, "spike");
            ghidra.framework.model.DomainFile file =
                project.getProject().getProjectData().getFile("/" + args[3]);
            program = (Program) file.getDomainObject(this, true, false, TaskMonitor.DUMMY);
            own = true;
        }
        log("opened " + program.getName() + " modnum=" + program.getModificationNumber()
            + " changed=" + program.isChanged() + " functions=" + program.getFunctionManager().getFunctionCount()
            + " openTx=" + program.getCurrentTransactionInfo());
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        server.setExecutor(Executors.newSingleThreadExecutor());
        server.createContext("/", this::handle);
        server.start();
        log("serving on " + port);
    }

    public static void main(String[] args) throws Exception {
        new Spike().launch(new GhidraApplicationLayout(), args);
    }

    private static void log(String text) { System.out.println("SPIKE " + text); System.out.flush(); }

    private void handle(HttpExchange exchange) {
        String answer;
        int status = 200;
        try {
            Map<String, String> q = query(exchange.getRequestURI().getRawQuery());
            String path = exchange.getRequestURI().getPath();
            answer = switch (path) {
                case "/hello" -> "modnum=" + program.getModificationNumber() + " changed=" + program.isChanged()
                    + " openTx=" + program.getCurrentTransactionInfo();
                case "/functions" -> functions();
                case "/rename" -> rename(q.get("entry"), q.get("name"));
                case "/save" -> { save(); yield "saved modnum=" + program.getModificationNumber() + " changed=" + program.isChanged(); }
                case "/locals" -> locals(q.get("entry"));
                case "/renamelocal" -> renameLocal(q.get("entry"), q.get("name"), q.get("to"));
                case "/c" -> decompile(function(q.get("entry"))).getDecompiledFunction().getC();
                case "/quit" -> { save(); if (own) program.release(this); project.close(); new Thread(() -> System.exit(0)).start(); yield "bye"; }
                default -> { throw new IllegalArgumentException("no " + path); }
            };
        } catch (Exception error) {
            status = 500;
            answer = error.toString();
        }
        try {
            byte[] bytes = (answer + "\n").getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(status, bytes.length);
            try (OutputStream out = exchange.getResponseBody()) { out.write(bytes); }
        } catch (Exception ignored) {}
    }

    private void save() throws Exception {
        if (own) program.save("spike", TaskMonitor.DUMMY); else project.save(program);
    }

    private Map<String, String> query(String raw) {
        Map<String, String> map = new HashMap<>();
        if (raw == null) return map;
        for (String pair : raw.split("&")) {
            String[] kv = pair.split("=", 2);
            map.put(kv[0], kv.length > 1 ? URLDecoder.decode(kv[1], StandardCharsets.UTF_8) : "");
        }
        return map;
    }

    private Function function(String entry) {
        Address address = program.getAddressFactory().getAddress(entry);
        Function f = program.getFunctionManager().getFunctionAt(address);
        if (f == null) throw new IllegalArgumentException("no function at " + entry);
        return f;
    }

    private String functions() {
        StringBuilder out = new StringBuilder();
        for (Function f : program.getFunctionManager().getFunctions(true)) {
            out.append(f.getEntryPoint()).append(' ').append(f.getName()).append(' ').append(f.getSymbol().getSource()).append('\n');
        }
        return out.toString();
    }

    private String rename(String entry, String name) throws Exception {
        Function f = function(entry);
        int tx = program.startTransaction("rename");
        boolean ok = false;
        try { f.setName(name, SourceType.USER_DEFINED); ok = true; }
        finally { program.endTransaction(tx, ok); }
        return "renamed " + f.getName() + " modnum=" + program.getModificationNumber();
    }

    private DecompileResults decompile(Function f) {
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(program);
        try { return decompiler.decompileFunction(f, 60, TaskMonitor.DUMMY); }
        finally { decompiler.dispose(); }
    }

    private String locals(String entry) {
        HighFunction high = decompile(function(entry)).getHighFunction();
        StringBuilder out = new StringBuilder();
        Iterator<HighSymbol> symbols = high.getLocalSymbolMap().getSymbols();
        while (symbols.hasNext()) {
            HighSymbol s = symbols.next();
            out.append(s.getName()).append(" storage=").append(s.getStorage())
               .append(" pc=").append(s.getPCAddress()).append(" param=").append(s.isParameter())
               .append(" id=").append(s.getId()).append('\n');
        }
        return out.toString();
    }

    private String renameLocal(String entry, String name, String to) throws Exception {
        HighFunction high = decompile(function(entry)).getHighFunction();
        Iterator<HighSymbol> symbols = high.getLocalSymbolMap().getSymbols();
        while (symbols.hasNext()) {
            HighSymbol s = symbols.next();
            if (s.getName().equals(name)) {
                int tx = program.startTransaction("rename local");
                boolean ok = false;
                try { HighFunctionDBUtil.updateDBVariable(s, to, null, SourceType.USER_DEFINED); ok = true; }
                finally { program.endTransaction(tx, ok); }
                return "renamed local " + name + " -> " + to + " storage=" + s.getStorage() + " pc=" + s.getPCAddress();
            }
        }
        throw new IllegalArgumentException("no local " + name);
    }
}
