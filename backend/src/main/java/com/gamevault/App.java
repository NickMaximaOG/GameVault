package com.gamevault;

/** Entry point: wires configuration, database, services and routes, then serves. */
public final class App {
    private App() {}

    /** Builds a ready-to-start server (used by main and by the integration tests). */
    public static Server build(Config cfg, Db db) {
        AuthService auth = new AuthService(db, cfg);
        Server server = new Server(cfg, auth);
        AuthRoutes.register(server, db, auth);
        CatalogRoutes.register(server, db);
        MeRoutes.register(server, db);
        AdminRoutes.register(server, db);
        return server;
    }

    public static void main(String[] args) throws Exception {
        Config cfg = Config.fromEnv();
        Db db = new Db(cfg);
        Server server = build(cfg, db);
        int port = server.start();
        System.out.println("{\"level\":\"INFO\",\"detail\":\"GameVault API listening on port " + port + "\"}");
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println("{\"level\":\"INFO\",\"detail\":\"shutting down\"}");
            server.stop();
            db.close();
        }));
        Thread.currentThread().join();
    }
}
