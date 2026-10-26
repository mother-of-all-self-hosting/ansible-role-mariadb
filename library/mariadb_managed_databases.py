#!/usr/bin/python
# SPDX-FileCopyrightText: 2026 Slavi Pantaleev
#
# SPDX-License-Identifier: AGPL-3.0-or-later

DOCUMENTATION = r"""
---
module: mariadb_managed_databases
short_description: Prepares managed MariaDB databases (users, passwords, databases, privileges)
description:
  - Inspects the server first and only runs the statements needed to bring each managed database
    (and its user) to the desired state, so that it can report whether anything changed.
  - Talks to MariaDB by running its client (via O(client_command)) and feeding it SQL on stdin,
    so that passwords never end up in files or on command lines.
  - Users are C('username'@'%') accounts authenticated via C(mysql_native_password). Their passwords
    are compared against the stored hashes, and new ones are sent as such hashes
    (C(IDENTIFIED BY PASSWORD)), so that they do not show up in server logs.
    A user authenticated in any other way gets its password set again (which switches it back to C(mysql_native_password)).
  - Existing databases are left as they are (their character set and collation are only used when creating them).
  - Requires MariaDB 10.4 or newer (it reads C(mysql.global_priv)). MySQL is not supported.
options:
  client_command:
    description:
      - The command (as a list of arguments) which starts the MariaDB client, connected as a superuser.
        Client arguments are appended to it. It has to pass stdin through (e.g. C(docker exec -i)).
      - O(login_password) is passed to it via the C(MYSQL_PWD) environment variable,
        so it has to pass that on (e.g. C(docker exec -e MYSQL_PWD)).
    type: list
    elements: str
    required: true
  login_password:
    description: The superuser's password.
    type: str
    required: true
    no_log: true
  databases:
    description: The managed databases.
    type: list
    elements: dict
    required: true
    options:
      name:
        type: str
        required: true
      username:
        type: str
        required: true
      password:
        type: str
        required: true
        no_log: true
      charset:
        description: The character set for the database, if it gets created.
        type: str
        required: true
      collation:
        description: The collation for the database, if it gets created.
        type: str
        required: true
  connection_retries:
    description: How many times to retry when the client cannot connect to MariaDB.
    type: int
    default: 0
  connection_retry_delay_seconds:
    description: How long to wait between connection retries.
    type: int
    default: 3
"""

RETURN = r"""
changes:
  description: Human-readable descriptions of the changes made (or which would be made, in check mode).
  type: list
  elements: str
  returned: always
"""

import binascii
import hashlib
import hmac
import json
import re
import time
import xml.etree.ElementTree as ET

from ansible.module_utils.basic import AnsibleModule

HOST = "%"

# Client errors which mean that the server could not be reached (or went away), as opposed to it rejecting something.
# See: https://mariadb.com/docs/server/reference/error-codes/mariadb-error-code-reference
CONNECTION_ERROR_RE = re.compile(r"^ERROR (2002|2003|2006|2013) ", re.MULTILINE)

XSI_NIL = "{http://www.w3.org/2001/XMLSchema-instance}nil"

NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")


def quote_ident(value):
    return "`" + value.replace("`", "``") + "`"


def quote_account(username):
    # Quoting the parts as identifiers (rather than strings) means that `sql_mode` (`NO_BACKSLASH_ESCAPES`) does not matter.
    return "%s@%s" % (quote_ident(username), quote_ident(HOST))


def hex_literal(value):
    # Same reason as above. These are only compared against binary (`utf8mb3_bin`) columns or exactly, in Python.
    return "X'%s'" % binascii.hexlify(value.encode("utf-8")).decode("ascii")


def native_password_hash(password):
    """The `mysql_native_password` hash (what `PASSWORD()` returns): `*` + SHA1(SHA1(password)) in upper-case hex."""
    return "*" + hashlib.sha1(hashlib.sha1(password.encode("utf-8")).digest()).hexdigest().upper()


def password_matches(priv, password):
    """Tells whether the account (its `mysql.global_priv` entry) authenticates via `mysql_native_password` with `password`."""
    if priv is None or priv.get("auth_or") or priv.get("plugin") != "mysql_native_password":
        return False
    return hmac.compare_digest(priv.get("authentication_string", ""), native_password_hash(password))


class Client(object):
    def __init__(self, module):
        self.module = module
        self.command = module.params["client_command"]
        self.environ = {"MYSQL_PWD": module.params["login_password"]}

    def run(self, sql, extra_args=None):
        args = self.command + (extra_args or [])
        attempts = 1 + max(self.module.params["connection_retries"], 0)
        for attempt in range(1, attempts + 1):
            rc, stdout, stderr = self.module.run_command(args, data=sql, binary_data=True, environ_update=self.environ)
            if rc == 0 or not CONNECTION_ERROR_RE.search(stderr) or attempt == attempts:
                break
            time.sleep(self.module.params["connection_retry_delay_seconds"])

        if rc != 0:
            self.module.fail_json(
                msg="Preparing the managed databases failed: the MariaDB client exited with code %d.\nOutput:\n%s" % (rc, stderr),
                rc=rc,
                stderr=stderr,
            )
        return stdout

    def query(self, sql):
        """Runs SELECT statements and returns the rows (dicts of column name to value, `None` for NULL) of each."""
        stdout = self.run(sql, ["--xml"])
        # Each statement's result set is a separate XML document.
        documents = [d for d in stdout.split('<?xml version="1.0"?>') if d.strip()]
        result_sets = []
        for document in documents:
            rows = []
            for row in ET.fromstring(document).iter("row"):
                rows.append(dict(
                    (field.get("name"), None if field.get(XSI_NIL) == "true" else (field.text or ""))
                    for field in row.iter("field")
                ))
            result_sets.append(rows)
        return result_sets


def inspect_server(client, databases):
    usernames = sorted({db["username"] for db in databases})
    names = sorted({db["name"] for db in databases})
    users_in = ", ".join(hex_literal(u) for u in usernames)
    names_in = ", ".join(hex_literal(n) for n in names)
    users, schemas, grants = client.query("""
SELECT User, Priv FROM mysql.global_priv WHERE Host = %(host)s AND User IN (%(users)s);
SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME IN (%(names)s);
SELECT * FROM mysql.db WHERE Host = %(host)s AND User IN (%(users)s) AND Db IN (%(names)s);
""" % dict(host=hex_literal(HOST), users=users_in, names=names_in))

    def has_all_privileges(row):
        # `ALL PRIVILEGES` on a database means every privilege column (which ones exist depends on the version) but `Grant_priv`.
        return all(value == "Y" for column, value in row.items() if column.endswith("_priv") and column != "Grant_priv")

    return dict(
        users=dict((row["User"], json.loads(row["Priv"])) for row in users),
        databases=set(row["SCHEMA_NAME"] for row in schemas),
        grants=set((row["User"], row["Db"]) for row in grants if has_all_privileges(row)),
    )


def main():
    module = AnsibleModule(
        argument_spec=dict(
            client_command=dict(type="list", elements="str", required=True),
            login_password=dict(type="str", required=True, no_log=True),
            databases=dict(
                type="list",
                elements="dict",
                required=True,
                options=dict(
                    name=dict(type="str", required=True),
                    username=dict(type="str", required=True),
                    password=dict(type="str", required=True, no_log=True),
                    charset=dict(type="str", required=True),
                    collation=dict(type="str", required=True),
                ),
            ),
            connection_retries=dict(type="int", default=0),
            connection_retry_delay_seconds=dict(type="int", default=3),
        ),
        supports_check_mode=True,
    )

    databases = module.params["databases"]
    if not databases:
        module.exit_json(changed=False, changes=[])

    for db in databases:
        for key in ("charset", "collation"):
            if not NAME_RE.match(db[key]):
                module.fail_json(msg="Invalid %s for the managed database `%s`: `%s`" % (key, db["name"], db[key]))

    client = Client(module)
    server = inspect_server(client, databases)
    users = server["users"]

    changes = []
    statements = []
    # Several managed databases may share a user. Its password is the last one given for it.
    passwords_set = {}
    for db in databases:
        name, username, password = db["name"], db["username"], db["password"]

        if username in passwords_set:
            password_ok = passwords_set[username] == password
        else:
            password_ok = username in users and password_matches(users[username], password)

        if not password_ok:
            password_hash = native_password_hash(password)
            module.no_log_values.add(password_hash)
            if username not in users:
                changes.append("create user %s" % quote_account(username))
                statements.append("CREATE USER %s IDENTIFIED BY PASSWORD '%s';" % (quote_account(username), password_hash))
                users[username] = None
            else:
                changes.append("set the password of user %s" % quote_account(username))
                statements.append("ALTER USER %s IDENTIFIED BY PASSWORD '%s';" % (quote_account(username), password_hash))
        passwords_set[username] = password

        if name not in server["databases"]:
            changes.append("create database %s" % quote_ident(name))
            statements.append(
                "CREATE DATABASE %s CHARACTER SET %s COLLATE %s;" % (quote_ident(name), db["charset"], db["collation"])
            )
            server["databases"].add(name)

        if (username, name) not in server["grants"]:
            changes.append("grant all privileges on database %s to %s" % (quote_ident(name), quote_account(username)))
            # Like before, `_` and `%` in the name act as wildcards (they are not escaped).
            statements.append("GRANT ALL PRIVILEGES ON %s.* TO %s;" % (quote_ident(name), quote_account(username)))
            server["grants"].add((username, name))

    changed = len(changes) > 0
    result = dict(changed=changed, changes=changes)
    if module._diff:
        result["diff"] = dict(before="", after="".join("%s\n" % c for c in changes))

    if module.check_mode or not changed:
        module.exit_json(**result)

    client.run("\n".join(statements) + "\n")
    module.exit_json(**result)


if __name__ == "__main__":
    main()
