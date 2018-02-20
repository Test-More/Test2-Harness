t2hui.build_job = function(job) {
    var root;

    root = t2hui.build_expander(job.short_file, 'job', function() {
        var controls = $('<ul class="job_controls"></ul>');
        var job_body = $('<div class="job_body"></div>');
        root.body.append(controls);
        root.body.append(job_body);

        var json = $('<li class="open_json">Details</li>');
        controls.prepend(json);
        json.click(function() {
            $('#modal_body').jsonView(job, {collapsed: true});
            $('#free_modal').slideDown();
        });

        var orphan_toggle = false;
        var orphans = $('<li class="load_orphans">Load Orphans</li>');
        controls.prepend(orphans);

        var spinner = $('<li class="spin_control"></li>');
        controls.append(spinner);

        var events = $('<div class="events"></div>');
        job_body.append(events);

        orphans.click(function() {
            events.empty();
            orphan_toggle = !orphan_toggle;
            t2hui.load_job_events(job, events, controls, orphan_toggle, spinner);
            if (orphan_toggle) {
                orphans.text('Unload Orphans');
            }
            else {
                orphans.text('Load Orphans');
            }
        });

        t2hui.load_job_events(job, events, controls, orphan_toggle, spinner);
    });

    return root.root;
};

t2hui.load_job_events = function(job, events, controls, load_orphans, spinner) {
    var uri = base_uri + 'job/' + job.job_id + '/events';
    var data = { 'load_orphans': load_orphans };

    t2hui.fetch(uri, {'data': data, 'spin_in': spinner}, function(e) {
        var parts = t2hui.build_event(e);
        events.append(parts);
    });
}

/*

        var first = 1;
        t2hui.fetch(uri, function(e) {
            var e_body = t2hui.build_event(e);

            if (first === 0) {
                job_body.append(e_body);
                return;
            }

            first = 0;

            var controls = $('<dl class="job_controls tiny"></dl>');
            var show_hidden = $('<dt><input type="checkbox" unchecked></input></dt><dd>Show Hidden Events</dd>');
            var show_orphans = $('<dt><input type="checkbox" unchecked></input></dt><dd>Show Orphan Events</dd>');

            show_hidden.find(':checkbox').click(function() { job_body.find('div.event.no_lines').slideToggle() });
            show_hidden.filter('dd').click(function() {
                show_hidden.find(':checkbox').each(function() { this.checked = !this.checked });
                job_body.find('div.event.no_lines').slideToggle();
            });

            show_orphans.find(':checkbox').click(function() { job_body.find('div.event.orphan').slideToggle() });
            show_orphans.filter('dd').click(function() {
                show_orphans.find(':checkbox').each(function() { this.checked = !this.checked });
                job_body.find('div.event.orphan').slideToggle();
            });

            controls.append(show_hidden);
            controls.append(show_orphans);
            job_body.append(controls);
            job_body.append(e_body);
        }, job_body);



 */
