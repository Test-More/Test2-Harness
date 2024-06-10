$(function() {
    var content = $('div#content');
    var runs    = $('div#run_list');

    var state = {
        'min': null,
        'max': null,
        'data': null,
        'rendered': null,
        'tailing': tailing,
        'selected': selected,
        'complete': false,
    };

    t2hui.fetch(
        data_uri + "/stream",
        {
            "done": function() {
                if (state.complete) { return }
                content.prepend('<div class="timeout">Connection has timed out, reload page to get updates.</div>');
            }
        },
        function(item) {
            if (!item)         { return                }
            if (item.complete) { state.complete = true }
            if (item.max)      { state.max = item.max  }
            if (item.min)      { state.min = item.min  }

            if (item.run_uuid) {
                var stream_url = base_uri + 'stream/run/' + item.run_uuid;
                var run_table = t2hui.runtable.build_table();
                runs.append(run_table.render());

                t2hui.fetch(
                    stream_url,
                    {},
                    function(item) {
                        if (item.type === 'run') {
                            run_table.render_item(item.data, item.data.run_uuid);
                        }
                    }
                );
            }

            redraw_resources(state, item.data);
        }
    );
});

function redraw_resources(state, data) {
    if (!state.min || !state.max) {
        return;
    }

    if (!state.rendered || !state.range) {
        var range   = {};
        range.dom   = $('<input type="range" min="' + state.min + '" max="' + state.max + '"></input>');
        range.tail  = $('<input type="button" value="&#9658;"></input>');
        range.stop  = $('<input type="button" value="&#9632;"></input>');
        range.prev  = $('<input type="button" value="&lt;"></input>');
        range.next  = $('<input type="button" value="&gt;"></input>');
        range.first = $('<input type="button" value="&lt;&lt;"></input>');
        range.last  = $('<input type="button" value="&gt;&gt;"></input>');

        var range_inner = $('<div class="range_selector_inner"></div>');
        var range_wrap  = $('<div class="range_selector"><h1>Timerange Selector</h1></div>');

        range.select = $('<div class="range_selector_select"></div>');

        range_inner.append(range.dom);
        range_wrap.append(range.last, range.next, range.tail, range.stop, range.prev, range.first, range_inner, range.select);

        state.pick_range = function(idx, idx_data) {
            range.dom.val(idx);
            state.selected = idx;
            render_resource(idx, idx_data);
        };

        var selector_change = function() {
            state.tailing = false;
            var idx = range.dom.val();
            state.pick_range(idx);
        };

        range.dom.on('input', selector_change);
        range.dom.change(selector_change);

        range.stop.click(function()  { state.tailing = false });
        range.tail.click(function()  { state.tailing = true;  state.pick_range(state.max)});
        range.first.click(function() { state.tailing = false; state.pick_range(state.min)});
        range.last.click(function()  { state.tailing = false; state.pick_range(state.max)});

        range.next.click(function() {
            var idx = range.dom.val();
            idx = Number(idx) + 1;
            if (idx > state.max) { return }
            state.tailing = false;
            state.pick_range(idx);
        });

        range.prev.click(function() {
            var idx = range.dom.val();
            idx = Number(idx) - 1;
            if (idx < state.min) { return }
            state.tailing = false;
            state.pick_range(idx);
        });

        state.rendered = $('div#resource_wrapper');
        state.rendered.removeClass('loading');
        state.rendered.addClass('rendered');
        state.rendered.empty();
        state.rendered.prepend(range_wrap);
        state.range = range;
    }

    var range = state.range;
    range.dom.attr('min', state.min);
    range.dom.attr('max', state.max);

    if (state.tailing && range.selected != state.max) {
        state.pick_range(state.max, data);
    }
}

function render_resource(idx, data) {
    if (data && data.ord == idx) {
        do_render_resource(idx, data.resources);
        return;
    }

    $.ajax(data_uri + '/' + idx, {
        'data': { 'content-type': 'application/json' },
        'error': function() {
            content.append('<div class="error">Could not load resources for index "' + idx + '"</div>');
        },
        'success': function(item) {
            do_render_resource(idx, item.resources);
        },
    });
}

function do_render_resource(idx, data) {
    var content = $('div#content');
    var resources = [];

    data.forEach(function(res) {
        var res = build_resource(res);
        resources.push(res);
    });

    content.children('div.resource').detach();
    content.append(resources);

    history.replaceState({"index": idx}, null, res_uri + '/' + idx);
}


function build_resource(item) {
    var res = $('<div class="resource"></div>');
    var name = $('<h1>' + item.name + '</h1>');
    res.append(name);

    if (item.data) {
        item.data.forEach(function(group) {
            build_group(res, group);
        });
    }

    return res;
}

function build_group(res, group) {
    if (group.title) { res.append('<h2>' + group.title + '</h2>') }

    if (group.tables) {
        group.tables.forEach(function(table) {
            build_table(res, table);
        });
    }

    if (group.lines) {
        group.lines.forEach(function(line) {
            res.append('<div class="group_line">' + line + '</div>');
        });
    }
}

function build_table(res, table) {
    if (table.title) { res.append('<h3>' + table.title + '</h3>') }

    var t = $('<table></table>');

    if (table.header) {
        var h = $('<tr></tr>');

        table.header.forEach(function(label) {
            h.append('<th>' + label + '</th>');
        });

        t.append(h);
    }

    table.rows.forEach(function(row) {
        var tr = $('<tr></tr>');

        row.forEach(function(td) {
            tr.append('<td>' + td + '</td>');
        });

        t.append(tr);
    });

    res.append(t);
}
