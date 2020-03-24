$(function() {
    $("div.dashboard").each(function() {
        var root = $('<div class="dashboard"></div>');
        root.append(t2hui.dashboard.build_controls(100));
        root.append(t2hui.dashboard.build_table(base_uri + 'runs/1/100'));

        $(this).replaceWith(root);
    });
});

t2hui.dashboard = {};

t2hui.dashboard.build_table = function(uri) {
    var columns = [
        { 'name': 'tools', 'label': 'tools', 'class': 'tools', 'builder': t2hui.dashboard.tool_builder },

        { 'name': 'passed',  'label': 'P', 'class': 'count', 'builder': t2hui.dashboard.build_pass },
        { 'name': 'failed',  'label': 'F', 'class': 'count', 'builder': t2hui.dashboard.build_fail },
        { 'name': 'retried', 'label': 'R', 'class': 'count', 'builder': t2hui.dashboard.build_retry },

        { 'name': 'project', 'label': 'project', 'class': 'project'},
        { 'name': 'status',  'label': 'status',  'class': 'status'}
    ];

    if (!single_user) {
        columns.push({ 'name': 'user', 'label': 'user', 'class': 'user'});
    }

    var table = new FieldTable({
        'class': 'dashboard_table',
        'id': 'dashboard_runs',
        'fetch': uri,
        'sortable': true,

        'modify_row_hook': t2hui.dashboard.modify_row,

        'row_redraw_check': t2hui.dashboard.redraw_check,
        'row_redraw_fetch': t2hui.dashboard.redraw_fetch,
        'row_redraw_interval': 5 * 1000,

        'dynamic_field_attribute': 'fields',
        'dynamic_field_fetch': t2hui.dashboard.field_fetch,
        'dynamic_field_builder': t2hui.dashboard.field_builder,

        'columns': columns,
        'postfix_columns': [
            { 'name': 'added', 'label': 'date+time (' + time_zone + ')', 'class': 'date' },
        ]
    });

    return table.render();
}

t2hui.dashboard.build_controls = function(count) {
    var page = 1;

    var controls = $('<div class="dashboard_controls"></div>');

    var pn = $('<span>' + page + '</span>');
    var dp = $('<div class="dashboard_page">Page </div>');
    dp.append(pn);

    var prev = $('<div class="dashboard_pager">&lt;&lt;</div>');
    prev.click(function() {
        page--;
        $("div#dashboard_runs").each(function() { $(this).replaceWith(t2hui.dashboard.build_table(base_uri + 'runs/' + page + '/' + count)) });
        if (page < 2) { prev.addClass('hide') }
        pn.text(page);
    });
    controls.append(prev);
    if (page < 2) { prev.addClass('hide') }

    controls.append(dp);


    var next = $('<div class="dashboard_pager">&gt;&gt;</div>');
    next.click(function() {
        page++;
        $("div#dashboard_runs").each(function() { $(this).replaceWith(t2hui.dashboard.build_table(base_uri + 'runs/' + page + '/' + count)) });
        if (page > 1) { prev.removeClass('hide') }
        pn.text(page);
    });
    controls.append(next);

    return controls;
}

t2hui.dashboard.build_pass = function(item, col) {
    var val = item.passed;
    if (val === null) { return };
    if (val === undefined) { return };
    col.text(val);
};

t2hui.dashboard.build_fail = function(item, col) {
    var val = item.failed;
    if (val === null) { return };
    if (val === undefined) { return };
    if (val == 0) { col.append($('<div class="success_txt">' + val + '</div>')) }
    else { col.text(val) }
};

t2hui.dashboard.build_retry = function(item, col) {
    var val = item.retried;
    if (val === null) { return };
    if (val === undefined) { return };
    if (val == 0) { col.append($('<div class="success_txt">' + val + '</div>')) }
    else { col.append($('<div class="iffy_txt">' + val + '</div>')) }
};

t2hui.dashboard.tool_builder = function(item, tools, data) {
    var link = base_uri + 'run/' + item.run_id;
    var downlink = base_uri + 'download/' + item.run_id;

    var params = $('<div class="tool etoggle" title="See Run Parameters"><img src="/img/data.png" /></div>');
    tools.append(params);
    params.click(function() {
        $('#modal_body').jsonView(item.parameters, {collapsed: true});
        $('#free_modal').slideDown();
    });

    var download = $('<a class="tool etoggle" title="Download Log" href="' + downlink + '"><img src="/img/download.png" /></a>');
    tools.append(download);

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
    else {
        var go = $('<a class="tool etoggle" title="Open Run" href="' + link + '"><img src="/img/goto.png" /></a>');
        tools.append(go);
    }

    var pin = $('<img />');
    var pintool = $('<a class="tool etoggle"></a>');

    var pinstate;
    if (item.pinned) {
        pintool.prop('title', 'unpin');
        pinstate = true;
        pin.attr('src', '/img/locked.png');
    }
    else {
        pintool.prop('title', 'pin');
        pinstate = false;
        pin.attr('src', '/img/unlocked.png');
    }

    pintool.append(pin);
    tools.prepend(pintool);

    pintool.click(function() {
        var url = link + '/pin';
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
                }
                else {
                    pintool.prop('title', 'pin');
                    pin.attr('src', '/img/unlocked.png');
                }

                pintool.append(pin);
            },
        });
    });
};

t2hui.dashboard.redraw_check = function(item) {
    if (item.status == 'pending') { return true }
    if (item.status == 'running') { return true }
    return false;
};

t2hui.dashboard.redraw_fetch = function(item) {
    return base_uri + 'run/' + item.run_id;
};

t2hui.dashboard.field_fetch = function(field_data) {
    return base_uri + 'run/' + field_data.run_id;
};

t2hui.dashboard.field_builder = function(data, name) {
    var it;
    data.fields.forEach(function(field) {
        if (field.name === name) {
            it = field.data;
            return false;
        }
    });

    return it;
};

t2hui.dashboard.modify_row = function(row, item) {
    if (item.failed) {
        row.addClass('error_set');
    }
    else if(item.passed) {
        row.addClass('success_set');
    }

    row.addClass(item.status + "_set");
};
