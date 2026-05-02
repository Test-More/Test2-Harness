use Test2::V0;
use App::Yath2::Util::IPC qw/resolve_ipc_filename/;

is(
    resolve_ipc_filename(
        project => 'fakeproj',
        user    => 'exodist',
        command => 'test',
        stamp   => '20260101-000000',
        pid     => 12345,
    ),
    'fakeproj-exodist-test-20260101-000000-yath-12345-ipc.json',
    'filename matches new ${project}-${user}-${command}-${stamp}-yath-${pid}-ipc.json shape',
);

is(
    resolve_ipc_filename(
        project => 'projX',
        user    => 'someone',
        command => 'start',
        stamp   => '20260429-153000',
        pid     => 99,
    ),
    'projX-someone-start-20260429-153000-yath-99-ipc.json',
    'start command works the same way',
);

like(
    dies { resolve_ipc_filename(user => 'u', command => 'test', stamp => '20260101-000000', pid => 1) },
    qr/project/,
    'project is required',
);

like(
    dies { resolve_ipc_filename(project => 'p', command => 'test', stamp => '20260101-000000', pid => 1) },
    qr/user/,
    'user is required',
);

like(
    dies { resolve_ipc_filename(project => 'p', user => 'u', stamp => '20260101-000000', pid => 1) },
    qr/command/,
    'command is required',
);

like(
    dies { resolve_ipc_filename(project => 'p', user => 'u', command => 'test', pid => 1) },
    qr/stamp/,
    'stamp is required',
);

like(
    dies { resolve_ipc_filename(project => 'p', user => 'u', command => 'test', stamp => '20260101-000000') },
    qr/pid/,
    'pid is required',
);

done_testing;
