t2hui.event_classes = {
    tag_watchers:   [],
    facet_watchers: [],
    tags_seen: {
        'DEBUG':  true, 'DIAG':   true, 'ERROR':  true, 'EVENT ID': true,
        'FAIL':   true, 'FATAL':  true, 'NOTE':   true, 'PASS':     true,
        'REASON': true, 'STDERR': true, 'STDOUT': true, 'TODO':     true
    },
    tags: [
        'DEBUG', 'DIAG',   'ERROR',  'EVENT ID', 'FAIL', 'FATAL', 'NOTE',
        'PASS',  'REASON', 'STDERR', 'STDOUT',   'TODO'
    ],
    facets_seen: {
        'about': true, 'amnesty': true, 'assert': true, 'error': true,
        'info':  true, 'plan':    true, 'time':   true
    },
    facets:[
        'about', 'amnesty', 'assert', 'error', 'info', 'plan', 'time'
    ]
};

t2hui.build_event = function(e, options) {
    var len = e.lines.length;

    if (options === undefined) {
        options = {};
    }

    var eclass = "";

    if (e.is_orphan) {
        eclass = eclass + " orphan";
    }
    if (e.nested) {
        eclass = eclass + " nested";
    }

    var st_width = 3 + (2 * e.nested);

    var ebreak  = $('<div class="event_break"></div>');
    var econt   = $('<div class="event_controls"></div>');
    var econt_i = $('<div class="event_controls_inner"></div>');

    var ftoggle = $('<div class="etoggle" title="See raw facet data">F</div>');
    econt_i.append(ftoggle);
    ftoggle.click(function() {
        $('#modal_body').jsonView(e.facets, {collapsed: true});
        $('#free_modal').slideDown();
    });

    if (e.cid) {
        var rtoggle = $('<div class="etoggle" title="See all related events">R</div>');
        econt_i.append(rtoggle);
        rtoggle.click(function() {
            var events = $('<div class="events"></div>');
            $('#modal_body').append(events);

            var uri = base_uri + 'cid/' + e.cid + '/' + e.job_id + '/events';
            t2hui.fetch(uri, {}, function(e2) {
                var sub_e = t2hui.build_event(e2, options);
                events.append(sub_e);
            });

            $('#free_modal').slideDown();
        });
    }

    econt.append(econt_i);

    var etoggle;
    if (e.is_parent && !options.no_subtest_toggle) {
        etoggle = $('<div class="etoggle subtest" title="load subtest"></div>');

        etoggle.one('click', function() {
            etoggle.toggleClass('clicked');

            var last = $(me.slice(-1)[0]);
            var uri = base_uri + 'event/' + e.event_id + '/events';
            t2hui.fetch(uri, {data: {load_orphans: e.is_orphan}, done: function() { etoggle.remove() } }, function(e2) {
                var sub_e = t2hui.build_event(e2, options);
                last.after(sub_e);
                last = $(sub_e.slice(-1)[0]);
            });
        });
    }

    var me = [ebreak[0], econt[0]];

    var toggle_added = false;

    if (len) {
        for (var i = 0; i < len; i++) {
            var line = e.lines[i];
            var facet = line[0];
            var tag = line[1];
            var content = line[2];

            if (content !== null && typeof(content) === 'object') {
                var data = content;
                content = $('<div class="open_event_json">* JSON, click here to open *</div>');

                content.click(function() {
                    $('#modal_body').jsonView(data, {collapsed: true});
                    $('#free_modal').slideDown();
                });
            }

            var et = null;
            if (etoggle && !toggle_added && facet === 'assert') {
                toggle_added = true;
                et = etoggle;
            }

            var cls = 'facet_' + t2hui.sanitize_class(facet) + ' tag_' + t2hui.sanitize_class(tag);
            var row = t2hui.build_event_flesh(facet, tag, content, st_width, et);
            $(row).addClass(cls);

            me = $.merge(me, row);
        }
    }

    var id_row = t2hui.build_event_flesh('', 'EVENT ID', e.event_id, st_width, (toggle_added ? null : etoggle));
    $(id_row).addClass('tag_EVENT-ID');
    me = $.merge(me, id_row);

    if (eclass) { $(me).addClass(eclass) }

    return me;
};

t2hui.build_event_flesh = function(facet, tag, text, st_width, st_toggle) {
    if (!t2hui.event_classes.tags_seen[tag]) {
        t2hui.event_classes.tags_seen[tag] = 1;
        t2hui.event_classes.tags.push(tag);
        t2hui.event_classes.tags.sort;
        $(t2hui.event_classes.tag_watchers).each(function() { this() })
    }
    if (facet && !t2hui.event_classes.facets_seen[facet]) {
        t2hui.event_classes.facets_seen[facet] = 1;
        t2hui.event_classes.facets.push(facet);
        t2hui.event_classes.facets.sort;
        $(t2hui.event_classes.facet_watchers).each(function() { this() })
    }

    var lbrace  = $('<div class="event_lbrace"></div>');
    var etag    = $('<div class="event_tag">' + tag + '</div>');
    var rbrace  = $('<div class="event_rbrace"></div>');
    var cwrap   = $('<div class="event_c_wrap"></div>');
    var stgap   = $('<div class="event_st_gap" style="width: ' + st_width + 'ch;"></div>');
    var content = $('<div class="event_content"></div>');

    content.append(text);
    cwrap.append(stgap, content);
    if (st_toggle) { stgap.append(st_toggle) }

    var me = [lbrace[0], etag[0], rbrace[0], cwrap[0]];
    $(me).attr('title', 'Facet: ' + facet);

    return me;
}
