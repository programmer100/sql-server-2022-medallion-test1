# SFTP CSV Bronze example

This is a fictional, non-deployed vertical slice for exercising the reusable
SFTP/ZIP/CSV components. It is not a production source contract and the example
table is not included in the DACPAC.

The example deliberately contains:

- a quoted comma;
- an embedded newline inside a quoted field;
- an invalid business date that Bronze must retain as text;
- an optional `promo_code` that exists in both the mapping and landing table;
- separate 4,000-character Bronze capacity and narrower Silver business rules.

Follow `docs/operations/sftp-csv-bronze.md` to install the table in a disposable
local database, create a ZIP, and run the end-to-end wrapper in local mode.

Before adapting it to a real feed:

1. copy and approve `docs/templates/source-contract.md`;
2. add the real Bronze heap to `database/Bronze/Tables`;
3. copy JSON to ignored `pipelines/bronze/config/*.local.json` files;
4. replace paths, vault name, remote mask, and the out-of-band-verified SSH host
   key fingerprint;
5. define Bronze-to-Silver validation, quarantine, deduplication, and typed target
   objects from the approved contract.
