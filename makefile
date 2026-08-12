.PHONY : clean deploy

deploy: .pyvenv
	.pyvenv/bin/python3 deploy.py

.pyvenv : deploy.py_requirements.txt
	python3 -m venv --upgrade .pyvenv
	.pyvenv/bin/pip --require-virtualenv install --upgrade -r deploy.py_requirements.txt
	echo .pyvenv Updated

clean :
	rm -rf .pyvenv