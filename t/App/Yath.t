use Test2::V0;
skip_all "TODO";

subtest load_command => sub {
    is(load_command('help'), 'App::Yath::Command::help', "Loaded the help command");
    is(
        dies { load_command('a_fake_command') },
        "yath command 'a_fake_command' not found. (did you forget to install App::Yath::Command::a_fake_command?)\n",
        "Exception if the command is not valid"
    );

    local @INC = ('t/lib', @INC);
    like(
        dies { load_command('broken') },
        qr/This command is broken! at/,
        "Exception is propogated if command dies on compile"
    );
};


