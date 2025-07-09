function handler(event) {
    var request = event.request;
    var uri = request.uri;

    // Check whether the URI ends with a slash (directory)
    if (uri.endsWith('/')) {
        request.uri += 'index.html';
    }
    // Check whether the URI is missing a file extension (like /en)
    else if (!uri.includes('.') && !uri.endsWith('/')) {
        request.uri += '/index.html';
    }

    return request;
}
