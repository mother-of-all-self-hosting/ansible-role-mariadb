<!--
SPDX-FileCopyrightText: 2020 - 2024 MDAD project contributors
SPDX-FileCopyrightText: 2020 - 2024 Slavi Pantaleev
SPDX-FileCopyrightText: 2020 Aaron Raimist
SPDX-FileCopyrightText: 2020 Chris van Dijk
SPDX-FileCopyrightText: 2020 Dominik Zajac
SPDX-FileCopyrightText: 2020 Mickaël Cornière
SPDX-FileCopyrightText: 2022 François Darveau
SPDX-FileCopyrightText: 2022 Julian Foad
SPDX-FileCopyrightText: 2022 Warren Bailey
SPDX-FileCopyrightText: 2023 Antonis Christofides
SPDX-FileCopyrightText: 2023 Felix Stupp
SPDX-FileCopyrightText: 2023 Pierre 'McFly' Marty
SPDX-FileCopyrightText: 2024 - 2025 Suguru Hirahara

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Setting up MariaDB

This is an [Ansible](https://www.ansible.com/) role which installs [MariaDB](https://mariadb.org) to run as a [Docker](https://www.docker.com/) container wrapped in a systemd service.

MariaDB is a powerful, open source object-relational database system.

See the project's [documentation](https://mariadb.org/documentation/) to learn what MariaDB does and why it might be useful to you.

## Adjusting the playbook configuration

To enable MariaDB with this role, add the following configuration to your `vars.yml` file.

**Note**: the path should be something like `inventory/host_vars/mash.example.com/vars.yml` if you use the [MASH Ansible playbook](https://github.com/mother-of-all-self-hosting/mash-playbook).

```yaml
########################################################################
#                                                                      #
# mariadb                                                              #
#                                                                      #
########################################################################

mariadb_enabled: true

# Put a strong password below, generated with `pwgen -s 64 1` or in another way
mariadb_root_password: ''

########################################################################
#                                                                      #
# /mariadb                                                             #
#                                                                      #
########################################################################
```

### Extending the configuration

There are some additional things you may wish to configure about the component.

Take a look at:

- [`defaults/main.yml`](../defaults/main.yml) for some variables that you can customize via your `vars.yml` file

## Installing

After configuring the playbook, run the installation command of your playbook as below:

```sh
ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start
```

If you use the MASH playbook, the shortcut commands with the [`just` program](https://github.com/mother-of-all-self-hosting/mash-playbook/blob/main/docs/just.md) are also available: `just install-all` or `just setup-all`

## Usage

After running the command for installation, the MariaDB instance becomes available.

### Getting a database terminal

You can use the CLI installed to the directory specified with `mariadb_bin_path` (default: `/mariadb/bin/`) for getting interactive terminal access to the MariaDB server.

>[!WARNING]
> Modifying the database directly (especially as services are running) is dangerous and may lead to irreversible database corruption. If you are not perfectly sure, create a backup!

### Backing up a database

The directory specified with `mariadb_backups_path` (default: `/mariadb/backups/`) is mounted as `/backups` into the container and is an allowed disk for backups called `backups`.

You can export a single database table by using the CLI tool and running a command like this:

```sql
BACKUP TABLE test TO Disk('backups', 'test.zip');
```

Read the [Backup and Restore](https://mariadb.com/docs/en/operations/backup) article in the official documentation to learn more.

>[!NOTE]
> For better (more en-masse) exporting, it may be beneficial to use the 3rd party [mariadb-backup](https://github.com/AlexAkulov/mariadb-backup) tool.

## Upgrading MariaDB

MariaDB is supposed to auto-upgrade its data as you upgrade to a newer version. There's nothing special that needs to be done.

## Troubleshooting

### Check the service's logs

You can find the logs in [systemd-journald](https://www.freedesktop.org/software/systemd/man/systemd-journald.service.html) by logging in to the server with SSH and running `journalctl -fu mariadb` (or how you/your playbook named the service, e.g. `mash-mariadb`).
