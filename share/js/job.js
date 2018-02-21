t2hui.build_job = function(job) {
    var root;

    t2hui.add_style('div.job_body.filter_tag_EVENT-ID > div.events > div.tag_EVENT-ID { display: none; }');

    root = t2hui.build_expander(job.short_file, 'job', function() {
        var controls = $('<ul class="job_controls"></ul>');
        var job_body = $('<div class="job_body filter_tag_EVENT-ID"></div>');
        root.body.append(controls);
        root.body.append(job_body);

        var json = $('<li class="open_json">Job JSON</li>');
        controls.prepend(json);
        json.click(function() {
            $('#modal_body').jsonView(job, {collapsed: true});
            $('#free_modal').slideDown();
        });

        var orphan_toggle = false;
        var orphans = $('<li class="load_orphans">Load Orphans</li>');
        controls.prepend(orphans);

        var subtest_toggle = false;
        var subtest = $('<li class="load_orphans">Open Subtests</li>');
        controls.prepend(subtest);

        var filter_facets = t2hui.build_filter('facet', 'Facet Filter', job_body, controls);
        controls.prepend(filter_facets);

        var filter_tags = t2hui.build_filter('tag', 'Tag Filter', job_body, controls);
        controls.prepend(filter_tags);

        var spinner = $('<li class="spin_control"></li>');
        controls.append(spinner);

        var events = $('<div class="events"></div>');
        job_body.append(events);

        orphans.click(function() {
            events.empty();
            orphan_toggle = !orphan_toggle;
            t2hui.load_job_events(job, events, controls, orphan_toggle, subtest_toggle, spinner);
            if (orphan_toggle) {
                orphans.text('Unload Orphans');
            }
            else {
                orphans.text('Load Orphans');
            }
        });

        subtest.click(function() {
            events.empty();
            subtest_toggle = !subtest_toggle;
            t2hui.load_job_events(job, events, controls, orphan_toggle, subtest_toggle, spinner);
            if (subtest_toggle) {
                subtest.text('Close Subtests');
            }
            else {
                subtest.text('Open Subtests');
            }
        });

        t2hui.load_job_events(job, events, controls, orphan_toggle, subtest_toggle, spinner);
    });

    return root.root;
};

t2hui.load_job_events = function(job, events, controls, load_orphans, load_subtests, spinner) {
    var uri = base_uri + 'job/' + job.job_id + '/events';
    var data = { 'load_orphans': load_orphans, 'load_subtests': load_subtests };

    t2hui.fetch(uri, {'data': data, 'spin_in': spinner}, function(e) {
        var parts = t2hui.build_event(e);
        events.append(parts);
    });
};


t2hui.build_filter = function(filter_type, text, job_body, controls) {
    var control = $('<li class="filter_' + filter_type + 's">' + text + '</li>');

    control.click(function() {
        var done = false;
        controls.siblings('div.job_filter').each(function() {
            var x = $(this);
            if (x.hasClass(filter_type)) { done = true; }
            x.slideUp(function() { x.remove() });
        });

        if (done) { return }

        var filter = $('<div class="job_filter ' + filter_type + 's" style="display: none;"><label>' + filter_type + ' filter</label></div>');
        var close = $('<div class="close">&otimes;</div>');
        filter.append(close);
        close.click(function() { filter.slideUp(function() { filter.remove() }) });

        var list = $('<ul class="job_filter_list"></ul>');
        filter.append(list);

        var populate = function() {
            list.empty();

            $(t2hui.event_classes[filter_type + 's']).each(function() {
                var it = this;
                var cl = filter_type + '_' + t2hui.sanitize_class(it);
                var fcl = 'filter_' + cl;
                var li = $('<li>' + it + '</li>');

                if (!job_body.hasClass(fcl)) { li.addClass('selected') }

                li.click(function() {
                    li.toggleClass('selected');
                    job_body.toggleClass(fcl);
                    t2hui.add_style('div.job_body.' + fcl + ' > div.events > div.' + cl + ' { display: none; }');
                });

                list.append(li);
            });
        };

        var watchers = t2hui.event_classes[filter_type + '_watchers'];
        watchers.push(populate);
        populate();

        filter.on("remove", function() {
            var idx = $.inArray(populate, watchers);
            if (idx == -1) { return };
            watchers.splice(idx, 1);
        });

        controls.before(filter);
        filter.slideDown();
    });

    return control;
};
