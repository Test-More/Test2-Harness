$(function() {
    $("div.run").each(function() {
        var root = $(this);

        var run_id = root.attr('data-run-id');
        var run_uri = base_uri + 'run/' + run_id;
        $.ajax(run_uri, {
            'data': { 'content-type': 'application/json' },
            'success': function(item) {
                var dash = t2hui.dashboard.build_table([item]);
                root.prepend($('<h3>Run: ' + run_id + '</h3>'), dash, $('<hr />'));
            },
        });

        var jobs_uri = run_uri + '/jobs';
        var table = t2hui.run.build_table(jobs_uri);
        root.append(table);
    });
});

t2hui.run = {};

t2hui.run.build_table = function(uri) {
    var columns = [
        { 'name': 'tools', 'label': 'tools', 'class': 'tools', 'builder': t2hui.run.tool_builder },

        { 'name': 'try', 'label': 'T', 'class': 'count', 'builder': t2hui.run.build_try },

        { 'name': 'pass_count',  'label': 'P', 'class': 'count', 'builder': t2hui.run.build_pass },
        { 'name': 'fail_count',  'label': 'F', 'class': 'count', 'builder': t2hui.run.build_fail },

        { 'name': 'exit',  'label': 'exit',  'class': 'exit', 'builder': t2hui.run.build_exit },

        { 'name': 'name', 'label': 'file/job name', 'class': 'job_name', 'builder': t2hui.run.build_name },
    ];

    var table = new FieldTable({
        'class': 'run_table',
        'id': 'run_jobs',
        'fetch': uri,
        'sortable': true,

        'modify_row_hook': t2hui.run.modify_row,
        'place_row': t2hui.run.place_row,

        'dynamic_field_attribute': 'fields',
        'dynamic_field_fetch': t2hui.run.field_fetch,
        'dynamic_field_builder': t2hui.run.field_builder,

        'columns': columns,
    });

    return table.render();
};

t2hui.run.build_pass = function(item, col, data) {
    var val = item.pass_count || '0';
    col.text(val);
    col.addClass('count');
};

t2hui.run.build_fail = function(item, col, data) {
    var val = item.fail_count || '0';
    col.text(val);
    col.addClass('count');
};

t2hui.run.build_try = function(item, col, data) {
    var val = item.job_try || '0';
    col.text(val);
    col.addClass('count');
};

t2hui.run.build_exit = function(item, col, data) {
    var val = item.exit != null ? item.exit : 'N/A';
    col.text(val);
};

t2hui.run.build_name = function(item, col, data) {
    var shrt = item.shortest_file || item.name;
    var lng  = item.file || item.name;

    var tt = t2hui.build_tooltip(col.parent(), lng);
    var tooltable = $('<table class="tool_table"></table>');
    var toolrow = $('<tr></tr>');
    tooltable.append(toolrow);

    var toolcol = $('<td></td>');
    toolcol.append(tt);

    var textcol = $('<td>' + shrt + '</td>');

    toolrow.append(toolcol, textcol);

    col.append(tooltable);
};

t2hui.run.tool_builder = function(item, tools, data) {
    var params = $('<div class="tool etoggle" title="See Job Parameters"><img src="/img/data.png" /></div>');
    tools.append(params);
    params.click(function() {
        $('#modal_body').empty();
        $('#modal_body').text("loading...");
        $('#free_modal').slideDown();

        var uri = base_uri + 'job/' + item.job_key;

        $.ajax(uri, {
            'data': { 'content-type': 'application/json' },
            'success': function(job) {
                $('#modal_body').empty();
                $('#modal_body').jsonView(job.parameters, {collapsed: true});
            },
        });
    });

    var link = base_uri + 'job/' + item.job_key;
    var go = $('<a class="tool etoggle" title="Open Job" href="' + link + '"><img src="/img/goto.png" /></a>');
    tools.append(go);
};

t2hui.run.modify_row = function(row, item) {
    if (item.short_file) {
        if (item.retry) {
            row.addClass('iffy_set');
            row.addClass('retry_txt');
        }
        else if (item.fail) {
            row.addClass('error_set');
        }
        else {
            row.addClass('success_set');
        }
    }
};

t2hui.run.field_builder = function(data, name) {
    var it;
    data.fields.forEach(function(field) {
        if (field.name === name) {
            it = field.data;
            return false;
        }
    });

    return it;
};

t2hui.run.field_fetch = function(field_data) {
    return base_uri + 'job/' + field_data.job_key;
};

t2hui.run.build_jobs = function(run_id) {
    var root = $('<div class="run" data-run-id="' + run_id + '"></div>');
    var uri = base_uri + 'run/' + run_id + "/jobs";
    var table = t2hui.run.build_table(uri);
    root.append(table);
    return root;
};

t2hui.run.place_row = function(row, item, table, state) {
    if (!item.short_file) {
        state['header'].after(row);
        return true;
    }

    if (item.fail && !item.retry) {
        if (state['fail']) {
            state['fail'].after(row);
        }
        else {
            state['body'].prepend(row);
        }

        state['fail'] = row;
        return true;
    }

    return false;
};
