$(function() {
    $("div.dashboard").each(function() { $(this).replaceWith(t2hui.build_dashboard(1, 100)) });

    setInterval(function() {
        Object.keys(t2hui.dashboard_to_update).forEach(function (run_id) {
            var old = t2hui.dashboard_to_update[run_id];
            delete t2hui.dashboard_to_update[run_id];

            var url = base_uri + 'run/' + run_id;
            $.ajax(url, {
                'data': { 'content-type': 'application/json' },
                'error': function(a, b, c) { t2hui.dashboard_to_update[run_id] = old },
                'success': function(item) {
                    var run = t2hui.build_dashboard_run(item);
                    $(old[0]).replaceWith(run);
                    old.remove();
                },
            });
        });
    }, 5 * 1000);
});

t2hui.dashboard_to_update = {};

t2hui.build_dashboard = function(page, count) {
    var root = $('<div class="dashboard"></div>');

    var controls = t2hui.build_dashboard_controls(page, count);
    var runs     = t2hui.build_dashboard_runs(null, page, count);

    root.append(controls);
    root.append(runs);

    return root;
}

t2hui.build_dashboard_controls = function(page, count) {
    var controls = $('<div class="dashboard_controls"></div>');

    if (page > 1) {
        var prev = $('<div class="dashboard_pager">&lt;&lt;</div>');
        prev.click(function() {
            $("div.dashboard").each(function() { $(this).replaceWith(t2hui.build_dashboard(page - 1, count)) });
        });
        controls.append(prev);
    }
    else {
        var prev = $('<div class="dashboard_pager hide">&nbsp;&nbsp;</div>');
        controls.append(prev);
    }

    controls.append('<div class="dashboard_page">Page ' + page + '</div>');

    var next = $('<div class="dashboard_pager">&gt;&gt;</div>');
    next.click(function() {
        $("div.dashboard").each(function() { $(this).replaceWith(t2hui.build_dashboard(page + 1, count)) });
    });
    controls.append(next);

    return controls;
}

t2hui.build_dashboard_runs = function(list, page, count) {
    var runs = $('<div class="dashboard_runs grid"></div>');

    runs.append($('<div class="col1 head tools">Tools</div>'));
    runs.append($('<div class="col2 head count">P</div>'));
    runs.append($('<div class="col3 head count">F</div>'));
    runs.append($('<div class="col4 head project">Project</div>'));
    runs.append($('<div class="col5 head version"><div class="head_collapse">Version</div></div>'));
    runs.append($('<div class="col6 head category"><div class="head_collapse">Category</div></div>'));
    runs.append($('<div class="col7 head tier"><div class="head_collapse">Tier</div></div>'));
    runs.append($('<div class="col8 head build"><div class="head_collapse">Build</div></div>'));
    runs.append($('<div class="col9 head status">Status</div>'));
    runs.append($('<div class="col10 head user"><div class="head_collapse">User</div></div>'));
    runs.append($('<div class="col11 head date">Date</div>'));

    if (list === null || list === undefined) {
        var uri = base_uri + 'runs/' + page + '/' + count;
        t2hui.fetch(uri, {}, function(item) {
            var run = t2hui.build_dashboard_run(item);
            runs.append(run);
        })
    }
    else {
        $(list).each(function() {
            var run = t2hui.build_dashboard_run(this);
            runs.append(run);
        });
    }

    return runs;
}

t2hui.dashboard_clean_maybe = function(thing) {
    if (thing === null) { return '' };
    if (thing === undefined) { return '' };
    return thing;
};

t2hui.dashboard_clean_maybe_fail = function(thing) {
    if (thing === null) { return '' };
    if (thing === undefined) { return '' };
    if (thing == 0) { return '<div class="success_txt">' + thing + '</div>' }
    return thing;
}

t2hui.build_dashboard_run = function(run) {
    var me = [];

    var tools = $('<div class="tools col1"></div>');
    me.push(tools[0]);

    var params = $('<div class="tool etoggle" title="See Run Parameters"><i class="far fa-list-alt"></i></div>');
    tools.append(params);
    params.click(function() {
        $('#modal_body').jsonView(run.parameters, {collapsed: true});
        $('#free_modal').slideDown();
    });

    var link = base_uri + 'run/' + run.run_id;

    if (run.error) {
        var err = $('<div class="tool etoggle error" title="See Error Message"><i class="fas fa-exclamation-triangle"></i></div>');
        tools.append(err);
        err.click(function() {
            var pre = $('<pre></pre>');
            pre.text(run.error);
            $('#modal_body').append(pre);
            $('#free_modal').slideDown();
        });
    }
    else {
        var go = $('<a class="tool etoggle" title="Open Run" href="' + link + '"><i class="fas fa-external-link-alt"></i></a>');
        tools.append(go);
    }

    var pin = $('<i class="fa-star"></i>');
    var pintool = $('<a class="tool etoggle"></a>');

    var pinstate;
    if (run.pinned) {
        pintool.prop('title', 'unpin');
        pinstate = true;
        pin.addClass('fas');
    }
    else {
        pintool.prop('title', 'pin');
        pinstate = false;
        pin.addClass('far');
    }

    pintool.append(pin);
    tools.prepend(pintool);

    pintool.click(function() {
        var url = link + '/pin';
        $.ajax(url, {
            'data': { 'content-type': 'application/json' },
            'error': function(a, b, c) { alert("Failed to pin run") },
            'success': function(item) {
                pinstate = !pinstate;
                pintool.children().remove();

                pin = $('<i class="fa-star"></i>');
                if (pinstate) {
                    pintool.prop('title', 'unpin');
                    pin.addClass('fas');
                }
                else {
                    pintool.prop('title', 'pin');
                    pin.addClass('far');
                }

                pintool.append(pin);
            },
        });

    });

    me.push($('<div class="col2 count success_txt">' + t2hui.dashboard_clean_maybe(run.passed) + '</div>')[0]);
    me.push($('<div class="col3 count error_txt">' + t2hui.dashboard_clean_maybe_fail(run.failed) + '</div>')[0]);
    me.push($('<div class="col4 project">' + run.project + '</div>')[0]);
    me.push($('<div class="col5 version"><div class="head_collapse">'  + t2hui.dashboard_clean_maybe(run.version)  + '</div></div>')[0]);
    me.push($('<div class="col6 category"><div class="head_collapse">' + t2hui.dashboard_clean_maybe(run.category) + '</div></div>')[0]);
    me.push($('<div class="col7 tier"><div class="head_collapse">'     + t2hui.dashboard_clean_maybe(run.tier)     + '</div></div>')[0]);
    me.push($('<div class="col8 build"><div class="head_collapse">'    + t2hui.dashboard_clean_maybe(run.build)    + '</div></div>')[0]);
    me.push($('<div class="col9 status">' + run.status + '</div>')[0]);
    me.push($('<div class="col10 user"><div class="head_collapse">' + run.user + '</div></div>')[0]);
    me.push($('<div class="col11 date">' + run.added + '</div>')[0]);

    var $me = $(me);

    $me.addClass(run.status + "_set");

    if (run.failed) {
        $me.addClass('error_set');
    }
    else if(run.passed) {
        $me.addClass('success_set');
    }

    $me.hover(
        function() { $me.addClass('hover') },
        function() { $me.removeClass('hover') },
    );

    if (run.status == 'pending' || run.status == 'running') {
        t2hui.dashboard_to_update[run.run_id] = $me;
    }

    return $me;
};
