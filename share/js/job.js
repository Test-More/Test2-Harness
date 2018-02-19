t2hui.build_job = function(job) {
    var root;

    root = t2hui.build_expander(job.short_file, 'job', function() {
        var details;
        details = t2hui.build_expander('Details', 'details', function() {
            var jsonv = $('<div class="job json-view"></div>');
            jsonv.jsonView(job, {collapsed: true});
            details.body.append(jsonv);
        });
        root.body.append(details.root);

        var job_body = $('<div class="job"></div>');

        var first = 1;
        var uri = base_uri + 'job/' + job.job_id + '/events';
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
        });

        root.body.append(job_body);
    });

    return root.root;
};
