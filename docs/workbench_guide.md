# Using the database in MySQL Workbench

1. **Connect.** Open Workbench, click the `+` next to *MySQL Connections*, set host `127.0.0.1`, port 3306, user `root`, and test it.
2. **Create the schema.** *File > Open SQL Script...* and choose `database/schema.sql`. Click the lightning-bolt button
   (Execute All). It creates `gamevault_db`, 21 tables, 8 views, 9 stored procedures, 22 triggers and one event, and loads the sample data.
   Run it once on a clean server. To start over, uncomment section 0 at the top of the file.
3. **Create the application accounts.** Open and run `database/security.sql`. Change the two passwords in it first.
4. **Check the data.** Open `database/validation.sql` and run it. Every row in the result should say `PASS`.
5. **Try queries.** Open `database/queries.sql`. Put the cursor inside one query and press `Ctrl+Enter` (Cmd+Enter on Mac) to run just that query.
6. **See the diagram.** *Database > Reverse Engineer...*, pick `gamevault_db`, and finish the wizard to get an EER diagram.
   `docs/er_diagram.mmd` holds the same model as a Mermaid diagram (paste it into mermaid.live to view it).
7. **Try the rules.** `database/negative_tests.sql` contains statements that **must fail** (each has an `Expected: ERROR nnnn` comment).
   Run them one at a time, since Workbench stops a script at the first error.

If the script stops with an error about `log_bin_trust_function_creators` when creating triggers or functions on a server with binary logging, run
`SET GLOBAL log_bin_trust_function_creators = 1;` as an administrator and run the script again from a clean state.
