t2hui.runtable = {};

t2hui.runtable.build_table = function() {
    var columns = [
        { 'name': 'tools', 'label': 'tools', 'class': 'tools', 'builder': t2hui.runtable.tool_builder },

        { 'name': 'concurrency',  'label': 'C', 'class': 'count', 'builder': t2hui.runtable.build_concurrency },
        { 'name': 'passed',  'label': 'P', 'class': 'count', 'builder': t2hui.runtable.build_pass },
        { 'name': 'failed',  'label': 'F', 'class': 'count', 'builder': t2hui.runtable.build_fail },
        { 'name': 'retried', 'label': 'R', 'class': 'count', 'builder': t2hui.runtable.build_retry },

        { 'name': 'project', 'label': 'project', 'class': 'project', 'builder': t2hui.runtable.build_project },
        { 'name': 'status',  'label': 'status',  'class': 'status'},
        { 'name': 'duration', 'label': 'duration', 'class': 'duration' },
    ];

    if (show_user || !single_user) {
        columns.push({ 'name': 'user', 'label': 'user', 'class': 'user', builder: t2hui.runtable.build_user});
    }

    var table = new FieldTable({
        'class': 'run_table',
        'id': 'runs',

        'updatable': true,

        'modify_row_hook': t2hui.runtable.modify_row,
        'place_row': t2hui.runtable.place_row,

        'dynamic_field_preprocess': t2hui.runtable.field_preprocess,
        'dynamic_field_attribute': 'fields',
        'dynamic_field_fetch': t2hui.runtable.field_fetch,

        'columns': columns,
        'postfix_columns': [
            { 'name': 'added', 'label': 'date+time (' + time_zone + ')', 'class': 'date' },
        ]
    });

    return table;
}

t2hui.runtable.place_row = function(row, item, table, state, existing) {
    if (existing) {
        return false;
    }

    if (!state['biggest']) {
        state['biggest'] = item.run_ord;
        return false;
    }

    if (item.run_ord > state.biggest) {
        state['biggest'] = item.run_ord;
        table.body.prepend(row);
        return true;
    }

    return false;
}

t2hui.runtable.build_project = function(item, col) {
    var val = item.project;
    if (val === null) { return };
    if (val === undefined) { return };

    var vlink = base_uri  + 'view/' + item.project_id;
    var slink = base_uri  + 'project/' + item.project_id;

    var stats = $('<a class="tool etoggle" title="Project Stats" href="' + slink + '"><img src="/img/stats.png" /></a>');
    var proj  = $('<a title="See runs for ' + val + '" href="' + vlink + '">' + val + '</a>');
    col.append(stats);
    col.append('&nbsp;');
    col.append(proj);
};

t2hui.runtable.build_user = function(item, col) {
    var val = item.user;
    if (val === null) { return };
    if (val === undefined) { return };

    var vlink = base_uri  + 'view/' + item.user_id;

    var proj  = $('<a title="See runs for ' + val + '" href="' + vlink + '">' + val + '</a>');
    col.append(proj);
};

t2hui.runtable.build_concurrency = function(item, col) {
    var val = item.concurrency;
    if (val === null) { return };
    if (val === undefined) { return };
    col.text("-j" + val);
};

t2hui.runtable.build_pass = function(item, col) {
    var val = item.passed;
    if (val === null) { return };
    if (val === undefined) { return };
    col.text(val);
};

t2hui.runtable.build_fail = function(item, col) {
    var val = item.failed;
    if (val === null) { return };
    if (val === undefined) { return };
    if (val == 0) { col.append($('<div class="success_txt">' + val + '</div>')) }
    else { col.append($('<a href="' + base_uri  + 'failed/' + item.run_id + '">' + val + '</a>')) }
};

t2hui.runtable.build_retry = function(item, col) {
    var val = item.retried;
    if (val === null) { return };
    if (val === undefined) { return };
    if (val == 0) { col.append($('<div class="success_txt">' + val + '</div>')) }
    else { col.append($('<div class="iffy_txt">' + val + '</div>')) }
};

t2hui.runtable.tool_builder = function(item, tools, data) {
    var link = base_uri + 'view/' + item.run_id;
    var downlink = base_uri + 'download/' + item.run_id;

    var params = $('<div class="tool etoggle" title="See Run Parameters"><img src="/img/data.png" /></div>');
    tools.append(params);
    params.click(function() {
        $('#modal_body').html("Loading...");
        $('#free_modal').slideDown();

        var url = base_uri + 'run/' + item.run_id + '/parameters';
        $.ajax(url, {
            'data': { 'content-type': 'application/json' },
            'error': function(a, b, c) { alert("Failed to load run paramaters") },
            'success': function(data) {
                var formatter = new JSONFormatter(data, 2);
                $('#modal_body').html(formatter.render());
            },
        });
    });

    if (item.log_file_id) {
        var download = $('<a class="tool etoggle" title="Download Log" href="' + downlink + '"><img src="/img/download.png" /></a>');
        tools.append(download);
    }
    else {
        var download = $('<a class="tool etoggle inactive" title="No Log To Download"><img src="/img/download.png" /></a>');
        tools.append(download);
    }

    if (item.status == 'broken') {
        var go = $('<a class="tool etoggle inactive" title="Cannot Open Run"><img src="/img/goto.png" /></a>');
        tools.append(go);
    }
    else {
        var go = $('<a class="tool etoggle" title="Open Run" href="' + link + '"><img src="/img/goto.png" /></a>');
        tools.append(go);
    }

    var del = $('<div class="tool etoggle" title="delete"><img src="/img/delete.png"/></div>');
    var pin = $('<img />');
    var pintool = $('<a class="tool etoggle"></a>');

    var pinstate;
    if (item.pinned == true) {
        pintool.prop('title', 'unpin');
        pinstate = true;
        pin.attr('src', '/img/locked.png');
        del.addClass('inactive');
    }
    else {
        pintool.prop('title', 'pin');
        pinstate = false;
        pin.attr('src', '/img/unlocked.png');
        del.removeClass('inactive');
    }

    if (item.status == 'running' || item.status == 'pending') {
        var cancel = $('<div class="tool etoggle error" title="cancel"><img src="/img/close.png"/></div>');
        tools.append(cancel);
        cancel.click(function() {
            var ok = confirm("Are you sure you wish to cancel this run? This action cannot be undone!\nNote: This only changes the runs status, it will not stop a running test. This is used to 'fix' an aborted run that is still set to 'running'");
            if (!ok) { return; }

            var url = base_uri + 'run/' + item.run_id + '/cancel';
            $.ajax(url, {
                'data': { 'content-type': 'application/json' },
                'error': function(a, b, c) { alert("Failed to cancel run") },
                'success': function() { return },
            });
        });
    }
    else {
        tools.append(del);

        del.click(function() {
            if (pinstate) {
                alert("Pinned runs cannot be deleted");
                return;
            }

            var ok = confirm("Are you sure you wish to delete this run? This action cannot be undone!");
            if (!ok) { return; }

            var url = base_uri + 'run/' + item.run_id + '/delete';
            $.ajax(url, {
                'data': { 'content-type': 'application/json' },
                'error': function(a, b, c) { alert("Could not delete run") },
                'success': function() {
                    $('tr#' + item.run_id).remove();
                },
            });
        });
    }

    var resources = $('<a class="tool etoggle unicode" title="resources" href="' + base_uri + 'resources/' + item.run_id + '">&#9851;</a>');
    tools.append(resources);

    var cimg = $('<img src="/img/coverage.png"/>');
    var dcimg = $('<img src="/img/coveragedel.png"/>');
    var cover = $('<div class="tool etoggle" title="coverage"></div>');
    var dcover = $('<div class="tool etoggle" title="delete coverage"></div>');
    dcover.append(dcimg);

    if (item.has_coverage && item.status === 'complete') {
        var curl = base_uri + 'coverage/' + item.run_id;
        var clink = $('<a href="' + curl + '">');
        clink.append(cimg);
        cover.append(clink);

        var dcurl = curl + '/delete';
        dcover.click(function() {
            var ok = confirm("Are you sure you wish to delete this coverage data? This action cannot be undone!");
            if (!ok) { return; }

            $.ajax(curl + '/delete', {
                'data': { 'content-type': 'application/json' },
                'error': function(a, b, c) { alert("Could not delete coverage") },
                'success': function() {
                    cover.addClass('inactive');
                    cover.click(function() { false });
                    dcover.addClass('inactive');
                    dcover.off('click');
                    dcover.click(function() { false });
                },
            });

        });
    }
    else {
        cover.append(cimg);
        cover.addClass('inactive');
        dcover.addClass('inactive');
    }

    tools.append(cover);
    tools.append(dcover);

    if (item.error) {
        var err = $('<div class="tool etoggle error" title="See Error Message"><img src="/img/error.png"/></div>');
        tools.append(err);
        err.click(function() {
            var pre = $('<pre></pre>');
            pre.text(item.error);
            $('#modal_body').append(pre);
            $('#free_modal').slideDown();
        });
    }

    pintool.append(pin);
    tools.prepend(pintool);

    pintool.click(function() {
        var url = base_uri + 'run/' + item.run_id + '/pin';
        $.ajax(url, {
            'data': { 'content-type': 'application/json' },
            'error': function(a, b, c) { alert("Failed to pin run") },
            'success': function() {
                pinstate = !pinstate;
                pintool.children().remove();

                pin = $('<img />');
                if (pinstate) {
                    pintool.prop('title', 'unpin');
                    pin.attr('src', '/img/locked.png');
                    del.addClass('inactive');
                }
                else {
                    pintool.prop('title', 'pin');
                    pin.attr('src', '/img/unlocked.png');
                    del.removeClass('inactive');
                }

                pintool.append(pin);
            },
        });
    });
};

t2hui.runtable.field_preprocess = function(field_data) {
    field_data.delete = base_uri + 'run/field/' + field_data.run_field_id + '/delete';
};

t2hui.runtable.field_fetch = function(field_data, item) {
    return base_uri + 'run/field/' + field_data.run_field_id;
};

t2hui.runtable.modify_row = function(row, item) {
    if (item.status == 'canceled') {
        row.addClass('iffy_set');
        return;
    }

    if (item.failed > 0) {
        row.addClass('error_set');
    }
    else if(item.passed > 0) {
        row.addClass('success_set');
    }

    row.addClass(item.status + "_set");
};
