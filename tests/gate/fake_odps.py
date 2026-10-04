#!/usr/bin/env python3
"""A warehouse double for the gate self-test.

Implements just enough of the ``odps.ODPS`` surface that
``scripts/mc_integration_support.py`` uses (list/create/exist/delete schema,
list/delete table) to let the *real* preflight and cleanup code run, with the state
kept in a JSON file so a test can read back which schemas a run created and dropped.

It is not a MaxCompute emulator: a relation created here exists because the code said
so. It exists so the gate's own decision logic can be executed on a machine that has no
credentials, no pyodps and no network - which is exactly the machine a fork pull request
runs on.
"""
import json
import os
import threading


class _Named:
    def __init__(self, name):
        self.name = name


class _State:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def read(self):
        if not os.path.exists(self.path):
            return {"schemas": {}}
        with open(self.path) as handle:
            return json.load(handle)

    def write(self, state):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as handle:
            json.dump(state, handle, sort_keys=True)
        os.replace(tmp, self.path)

    def mutate(self, fn):
        with self.lock:
            state = self.read()
            result = fn(state)
            self.write(state)
            return result


class ODPS:
    def __init__(self, access_id=None, secret_access_key=None, project=None, endpoint=None):
        if not access_id or not secret_access_key:
            raise RuntimeError("fake ODPS still requires credentials in the environment")
        self.project = project
        self.endpoint = endpoint
        self._state = _State(os.environ.get("FAKE_ODPS_STATE", "fake-odps-state.json"))

    def list_schemas(self):
        return [_Named(name) for name in sorted(self._state.read()["schemas"])]

    def create_schema(self, name):
        def do(state):
            state["schemas"].setdefault(name, [])
        self._state.mutate(do)

    def exist_schema(self, name):
        return name in self._state.read()["schemas"]

    def delete_schema(self, name):
        def do(state):
            state["schemas"].pop(name, None)
        self._state.mutate(do)

    def list_tables(self, schema=None):
        state = self._state.read()
        return [_Named(name) for name in sorted(state["schemas"].get(schema, []))]

    def delete_table(self, name, schema=None, if_exists=False):
        def do(state):
            relations = state["schemas"].get(schema, [])
            if name in relations:
                relations.remove(name)
            elif not if_exists:
                raise KeyError("%s.%s does not exist" % (schema, name))
        self._state.mutate(do)


def seed_relation(state_path, schema, relation):
    """Let a test put a relation inside a schema, e.g. to represent another run's work."""
    state = _State(state_path)

    def do(data):
        data["schemas"].setdefault(schema, []).append(relation)
    state.mutate(do)
