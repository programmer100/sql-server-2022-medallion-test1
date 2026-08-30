# Gold pipelines

Document or implement business-model loads here. Define dependencies, dimensional grain, SCD behavior, late-arriving facts and dimensions, reconciliation, and consumer SLAs.

Gold loads may consume Silver or other Gold objects, but must not bypass Silver
to read Bronze. Do not add a Gold object until its source contract identifies a
real consumer, grain, history behavior, and metric definitions.
