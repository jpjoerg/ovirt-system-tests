#
# Copyright 2014 Red Hat, Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301 USA
#
# Refer to the README and COPYING files for full details of the license
#
from __future__ import absolute_import

import os
import tempfile

import ovirtsdk4.types as types

from ovirtlago import testlib

import test_utils
from ost_utils.pytest.fixtures import api_v4, prefix

# AAA
AAA_LDAP_USER = 'user1'
AAA_LDAP_GROUP = 'mygroup'
AAA_LDAP_AUTHZ_PROVIDER = 'lago.local-authz'
HOSTNAME_389DS = testlib.get_prefixed_name('engine')


def test_add_ldap_provider(prefix):
    engine = prefix.virt_env.engine_vm()
    machine_389ds = prefix.virt_env.get_vm(HOSTNAME_389DS)

    answer_file_src = os.path.join(
        os.environ.get('SUITE'),
        'aaa-ldap-answer-file.conf'
    )

    with open(answer_file_src, 'r') as f:
        content = f.read()
        content = content.replace('@389DS_IP@', machine_389ds.ip())

    with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp:
        temp.write(content)
    engine.copy_to(temp.name, '/root/aaa-ldap-answer-file.conf')
    os.unlink(temp.name)

    result = machine_389ds.ssh(
        [
            'systemctl',
            'start',
            'dirsrv@lago',
        ],
    )
    assert result.code == 0, \
        'Failed to start LDAP server. Exit code %s' % result.code

    result = engine.ssh(
        [
            'ovirt-engine-extension-aaa-ldap-setup',
            '--config-append=/root/aaa-ldap-answer-file.conf',
            '--log=/var/log/ovirt-engine-extension-aaa-ldap-setup.log',
        ],
    )
    assert result.code == 0, \
        'aaa-ldap-setup failed. Exit code is %s' % result.code

    engine.service('ovirt-engine')._request_stop()
    testlib.assert_true_within_long(
        lambda: not engine.service('ovirt-engine').alive()
    )
    engine.service('ovirt-engine')._request_start()
    testlib.assert_true_within_long(
        lambda: engine.service('ovirt-engine').alive()
    )


def test_add_ldap_group(api_v4):
    engine = api_v4.system_service()
    groups_service = engine.groups_service()
    with test_utils.TestEvent(engine, 149): # USER_ADD(149)
        groups_service.add(
            types.Group(
                name=AAA_LDAP_GROUP,
                domain=types.Domain(
                    name=AAA_LDAP_AUTHZ_PROVIDER
                ),
            ),
        )


def test_add_ldap_user(api_v4):
    engine = api_v4.system_service()
    users_service = engine.users_service()
    with test_utils.TestEvent(engine, 149): # USER_ADD(149)
        users_service.add(
            types.User(
                user_name=AAA_LDAP_USER,
                domain=types.Domain(
                    name=AAA_LDAP_AUTHZ_PROVIDER
                ),
            ),
        )
