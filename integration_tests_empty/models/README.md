Deliberately empty. `dbt_project.yml` points `model-paths` here so the project
parses as a real (but resource-free) dbt project; the only graph nodes that
exist are the ones the package itself brings in.
