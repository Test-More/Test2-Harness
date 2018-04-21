$(function() {
    $("div.job").each(function() {
        var me = $(this);
        t2hui.build_job(me.attr('data-job-id'), me);
    });
});

t2hui.filters = { seen: {}, state: {} };

t2hui.build_job = function(job_id, root, list) {
    if (root === null || root === undefined) {
        root = $('<div class="job" data-job-id="' + run_id + '"></div>');
    }

    var job_uri = base_uri + 'job/' + job_id;
    var events_uri = job_uri + '/events';

    $.ajax(job_uri, {
        'data': { 'content-type': 'application/json' },
        'success': function(item) {
            var job_grid = $('<div class="job_list grid"></div>');
            var jhead = t2hui.build_run_job(item);

            job_grid.append(t2hui.build_run_job_header());
            job_grid.append(jhead);

            root.prepend($('<h3>Job: ' + job_id + '</h3>'), job_grid, $('<hr />'));
        },
    });

    var events = $('<div class="event_list grid"></div>');
    events.append(t2hui.build_job_event_header());

    if (!t2hui.filters.dom) {
        var filter = $('<div class="event_filter_wrapper">Filter Tags:</div>');
        var filters = $('<ul class="event_filter"></ul>');
        filter.append(filters);

        t2hui.filters.dom = filter;
        t2hui.filters.listdom = filters;
    }

    root.append(t2hui.filters.dom, events);

    t2hui.fetch(events_uri, {}, function(e) {
        events.append(t2hui.render_event(e));
    });

    return root;
};

t2hui.build_job_event_header = function(job) {
    var me = [
        $('<div class="col1 head tools">Tools</div>'),
        $('<div class="col2 head">Tag</div>'),
        $('<div class="col3 head">Message</div>'),
    ];

    return me;
}

t2hui.render_event = function(e) {
    var me = [];
    var len = e.lines.length;

    var etools = [];

    if (e.facets) {
        var efacet = $('<div class="tool etoggle" title="See Raw Facet Data"><i class="far fa-list-alt"></i></div>');
        etools.push(efacet);
        efacet.click(function() {
            $('#modal_body').jsonView(e.facets, {collapsed: true});
            $('#free_modal').slideDown();
        });
    }

    if (e.orphan) {
        var eorphan = $('<div class="tool etoggle" title="See Orphan Facet Data"><i class="fas fa-code-branch"></i></div>');
        etools.push(eorphan);
        eorphan.click(function() {
            $('#modal_body').jsonView(e.orphan, {collapsed: true});
            $('#free_modal').slideDown();
        });
    }

    var nested = e.nested;
    var indent = '' + ((nested + 1) * 2) + 'ch';

    var f;
    if (e.facets && e.facets.hubs) {
        f = e.facets;
    }
    else if (e.orphan && e.orphan.hubs) {
        f = e.orphan;
    }

    var p = f && f.parent;

    var seen = t2hui.filters.seen;
    var state = t2hui.filters.state;
    var filters = t2hui.filters.listdom;

    for (var i = 0; i < len; i++) {
        var line = e.lines[i];

        if (!seen[line[1]]) {
            seen[line[1]] = 1;
            state[line[1]] = true;

            var filter = $('<li class="tag_filter">' + line[1] + '</li>');
            filter.click(function() {
                state[line[1]] = !state[line[1]];
                if (state[line[1]]) {
                    filter.removeClass('off');
                    $('div.tag_' + line[1]).show()
                }
                else {
                    filter.addClass('off');
                    $('div.tag_' + line[1]).hide()
                }
            });

            var added = false;
            var others = filters.children().toArray();
            for (var j = 0; j < others.length; j++) {
                if ($(others[j]).text() > line[1]) {
                    $(others[j]).before(filter);
                    added = true;
                    break;
                }
            }

            if (!added) { filters.append(filter) };
        }

        var classes = 'facet_' + line[0] + ' tag_' + line[1]

        var ltools = $('<div class="col1 ' + classes + ' tools"></div>');
        ltools.append(etools);

        var render = $('<div class="col3 message ' + classes + '" style="padding-left: ' + indent + '"></div>');
        var pre = $('<pre class="testout"></pre>');
        pre.append(line[2]);
        render.append(pre);

        if (p && line[0] == 'assert') {
            var expand = $('<div class="stoggle">+</div>');
            expand.one('click', function() {
                expand.detach();
                var events_uri = base_uri + 'event/' + e.event_id + '/events';
                var before = me[me.length - 1];
                t2hui.fetch(events_uri, {}, function(se) {
                    var it = t2hui.render_event(se, filters, seen);
                    before.after(it);
                    before = it[it.length - 1];
                });
            });
            render.prepend(expand);
        }

        var tag = $('<div class="col2 tag ' + classes + '">' + line[1] + '</div>');

        if (!state[line[1]]) {
            ltools.hide();
            tag.hide();
            render.hide();
        }

        me.push(ltools);
        me.push(tag);
        me.push(render);
    }

    return me;
}
